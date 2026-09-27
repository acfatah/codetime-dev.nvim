local H = require "tests.helpers"
local eq = H.eq

local child = H.new_child()
local T = MiniTest.new_set { hooks = { pre_case = child.setup, post_once = child.stop } }

local PAYLOAD_KEYS = {
  "absoluteFile",
  "editor",
  "eventTime",
  "eventType",
  "gitBranch",
  "gitOrigin",
  "language",
  "operationType",
  "platform",
  "platformArch",
  "project",
  "relativeFile",
}

local function last_event() return child.events()[#child.events()] end

-- write events only; cursor motion during edits also sends read events
local function writes()
  local types = {}
  for _, event in ipairs(child.events()) do
    if event.operationType == "write" then table.insert(types, event.eventType) end
  end
  return types
end

T["payload"] = MiniTest.new_set()

T["payload"]["has exactly the VS Code fields"] = function()
  local dir = child.git_repo { origin = "https://example.com/repo.git" }
  child.edit("src/main.lua", { "print(1)" })

  local event = last_event()
  local keys = vim.tbl_keys(event)
  table.sort(keys)
  eq(keys, PAYLOAD_KEYS)
  eq(event.project, vim.fs.basename(dir))
  eq(event.language, "lua")
  eq(event.relativeFile, "src/main.lua")
  eq(event.absoluteFile, dir .. "/src/main.lua")
  eq(event.editor, "Neovim")
  eq(event.eventTime, 1700000000000)
  eq(event.eventType, "activateFileChanged")
  eq(event.gitOrigin, "https://example.com/repo.git")
  eq(event.gitBranch, "main")
  eq(event.operationType, "read")
end

T["payload"]["platform and Node-style arch"] = function()
  local dir = child.tmpdir()
  child.edit("a.txt", { "" })
  local uname = child.lua_get "vim.uv.os_uname()"
  local node_arch = ({ x86_64 = "x64", amd64 = "x64", aarch64 = "arm64", armv7l = "arm", i686 = "ia32" })[uname.machine]
  eq(last_event().platform, uname.sysname .. " " .. uname.release)
  eq(last_event().platformArch, node_arch or uname.machine)
  eq(last_event().project, vim.fs.basename(dir))
end

T["payload"]["editor name is configurable"] = function()
  child.setup { setup = { editor = "Neovide" } }
  child.tmpdir()
  child.edit("a.txt", { "" })
  eq(last_event().editor, "Neovide")
end

T["payload"]["language falls back to plaintext"] = function()
  child.tmpdir()
  child.edit("notes.unknownext", { "" })
  eq(last_event().language, "plaintext")
end

T["payload"]["project is the git root even when cwd is elsewhere"] = function()
  local repo = child.git_repo()
  child.tmpdir() -- moves cwd out of the repo
  child.edit(repo .. "/lib/x.lua", { "" })
  eq(last_event().project, vim.fs.basename(repo))
  eq(last_event().relativeFile, "lib/x.lua")
end

T["payload"]["file outside the project is [other workspace]"] = function()
  local outside = child.tmpdir()
  local cwd = child.tmpdir()
  child.edit(outside .. "/a.txt", { "" })
  eq(last_event().project, vim.fs.basename(cwd))
  eq(last_event().relativeFile, "[other workspace]")
  eq(last_event().absoluteFile, outside .. "/a.txt")
end

T["autocmds"] = MiniTest.new_set {
  hooks = {
    pre_case = function()
      child.tmpdir()
      child.edit("a.txt", { "one", "two" })
      child.clear_requests()
    end,
  },
}

T["autocmds"]["BufEnter sends activateFileChanged (read)"] = function()
  child.edit("b.txt", { "" })
  eq(child.event_types(), { "activateFileChanged" })
  eq(last_event().operationType, "read")
end

T["autocmds"]["FocusGained sends editorChanged (read)"] = function()
  child.cmd "doautocmd FocusGained"
  eq(child.event_types(), { "editorChanged" })
  eq(last_event().operationType, "read")
end

T["autocmds"]["text change sends fileEdited (write)"] = function()
  child.type_keys "x"
  eq(writes(), { "fileEdited" })
end

T["autocmds"]["insert-mode change sends fileEdited"] = function()
  child.type_keys("A", "!")
  eq(writes(), { "fileEdited" })
  child.type_keys "<Esc>"
end

T["autocmds"][":w sends fileSaved (write)"] = function()
  child.cmd "write"
  eq(child.event_types(), { "fileSaved" })
  eq(last_event().operationType, "write")
end

T["ignored buffers"] = MiniTest.new_set()

T["ignored buffers"]["unnamed buffer"] = function()
  child.cmd "enew"
  child.type_keys "ihello<Esc>"
  eq(child.events(), {})
end

T["ignored buffers"]["special buffer (buftype set)"] = function()
  child.tmpdir()
  -- how plugins create file trees, pickers, etc.
  child.lua [[
    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, "scratch")
    vim.api.nvim_set_current_buf(buf)
  ]]
  child.type_keys "ihello<Esc>"
  child.cmd "doautocmd FocusGained"
  eq(child.events(), {})
end

T["ignored buffers"]["help"] = function()
  child.cmd "help"
  eq(child.events(), {})
end

T["throttle"] = MiniTest.new_set {
  hooks = {
    pre_case = function()
      child.tmpdir()
      child.edit("a.txt", { "one" })
      child.edit("b.txt", { "two" })
      child.clear_requests()
    end,
  },
}

T["throttle"]["read events: once per file per read_throttle"] = function()
  child.cmd "buffer a.txt"
  child.cmd "buffer b.txt"
  child.cmd "buffer a.txt"
  eq(#child.events(), 0) -- both already sent when opened

  child.advance(119999)
  child.cmd "buffer b.txt"
  eq(#child.events(), 0)

  child.advance(1)
  child.cmd "buffer a.txt"
  child.cmd "buffer b.txt"
  eq(child.event_types(), { "activateFileChanged", "activateFileChanged" })
end

T["throttle"]["each event type has its own window"] = function()
  child.cmd "doautocmd FocusGained"
  eq(child.event_types(), { "editorChanged" })
end

T["throttle"]["edits: once per file per write_throttle"] = function()
  child.type_keys "x"
  child.type_keys "x"
  eq(writes(), { "fileEdited" })
  child.advance(10000)
  child.type_keys "x"
  eq(writes(), { "fileEdited", "fileEdited" })
end

T["throttle"]["saves are never throttled"] = function()
  child.cmd "write"
  child.cmd "write"
  eq(child.event_types(), { "fileSaved", "fileSaved" })
end

T["throttle"]["throttle options are respected"] = function()
  child.setup { setup = { read_throttle = 5, write_throttle = 5 } }
  child.tmpdir()
  child.edit("a.txt", { "one" })
  child.edit("b.txt", { "two" })
  child.advance(5)
  child.cmd "buffer a.txt"
  eq(child.event_types(), { "activateFileChanged", "activateFileChanged", "activateFileChanged" })
end

T["git fields"] = MiniTest.new_set()

T["git fields"]["are empty strings outside a repo"] = function()
  child.tmpdir()
  child.edit("a.txt", { "" })
  eq(last_event().gitOrigin, "")
  eq(last_event().gitBranch, "")
end

T["git fields"]["origin is an empty string without a remote"] = function()
  child.git_repo { branch = "dev" }
  child.edit("a.txt", { "" })
  eq(last_event().gitOrigin, "")
  eq(last_event().gitBranch, "dev")
end

T["git fields"]["detached HEAD reports HEAD"] = function()
  child.git_repo { origin = "git@example.com:r.git", detached = true }
  child.edit("a.txt", { "" })
  eq(last_event().gitOrigin, "git@example.com:r.git")
  eq(last_event().gitBranch, "HEAD")
end

T["git fields"]["branch is refreshed on FocusGained"] = function()
  local dir = child.git_repo()
  child.edit("a.txt", { "" })
  vim.system({ "git", "-C", dir, "checkout", "-q", "-b", "feature" }):wait()
  child.cmd "doautocmd FocusGained"
  -- the refresh is async; wait for it to land
  eq(
    child.lua_get [[vim.wait(2000, function() return require("codetime_dev.project").info(0).git_branch == "feature" end, 10)]],
    true
  )
  child.advance(120000)
  child.cmd "doautocmd FocusGained"
  eq(last_event().gitBranch, "feature")
end

T["project lookup runs only for events that pass the throttle"] = function()
  child.tmpdir()
  child.edit("a.txt", { "" })
  child.lua [[
    local project = require "codetime_dev.project"
    local info = project.info
    _G.info_calls = 0
    project.info = function(...)
      _G.info_calls = _G.info_calls + 1
      return info(...)
    end
  ]]
  for _ = 1, 5 do
    child.type_keys "ix<Esc>"
  end
  eq(writes(), { "fileEdited" })
  eq(child.lua_get "_G.info_calls", #child.events() - 1) -- minus the BufEnter before wrapping
end

T["fileAddedLine"] = MiniTest.new_set {
  hooks = {
    pre_case = function()
      child.tmpdir()
      child.edit("a.txt", { "one", "two" })
      child.clear_requests()
    end,
  },
}

T["fileAddedLine"]["sent when an edit adds a line (write)"] = function()
  child.type_keys "yyp"
  eq(writes(), { "fileAddedLine" })
end

T["fileAddedLine"]["sent for Enter in insert mode"] = function()
  child.type_keys("A", "<CR>", "<Esc>")
  eq(writes(), { "fileAddedLine" })
end

T["fileAddedLine"]["not for edits that keep or remove lines"] = function()
  child.type_keys "x"
  child.advance(10000)
  child.type_keys "dd"
  eq(writes(), { "fileEdited", "fileEdited" })
end

T["fileAddedLine"]["throttled separately from fileEdited"] = function()
  child.type_keys "x"
  child.type_keys "yyp"
  child.type_keys "yyp"
  child.type_keys "x"
  eq(writes(), { "fileEdited", "fileAddedLine" })
  child.advance(10000)
  child.type_keys "yyp"
  eq(writes(), { "fileEdited", "fileAddedLine", "fileAddedLine" })
end

T["cursor and scroll"] = MiniTest.new_set {
  hooks = {
    pre_case = function()
      child.tmpdir()
      local lines = {}
      for i = 1, 200 do
        lines[i] = "line " .. i
      end
      child.edit("long.txt", lines)
      child.clear_requests()
    end,
  },
}

T["cursor and scroll"]["CursorMoved sends changeEditorSelection (read)"] = function()
  child.type_keys "j"
  eq(child.event_types(), { "changeEditorSelection" })
  eq(last_event().operationType, "read")
end

T["cursor and scroll"]["WinScrolled sends changeEditorVisibleRanges (read)"] = function()
  child.type_keys "<C-e>"
  eq(vim.tbl_contains(child.event_types(), "changeEditorVisibleRanges"), true)
  eq(last_event().operationType, "read")
end

T["cursor and scroll"]["once per file per cursor_throttle (30s)"] = function()
  child.type_keys "j"
  child.type_keys "j"
  eq(#child.events(), 1)
  child.advance(29999)
  child.type_keys "j"
  eq(#child.events(), 1)
  child.advance(1)
  child.type_keys "j"
  eq(child.event_types(), { "changeEditorSelection", "changeEditorSelection" })
end

T["cursor and scroll"]["cursor_throttle option"] = function()
  eq(child.lua_get [[require("codetime_dev.config").options.cursor_throttle]], 30000)
  child.setup { setup = { cursor_throttle = 5 } }
  child.tmpdir()
  child.edit("a.txt", { "one", "two", "three" })
  child.clear_requests()
  child.type_keys "j"
  child.advance(5)
  child.type_keys "j"
  eq(child.event_types(), { "changeEditorSelection", "changeEditorSelection" })
end

T["FocusLost sends editorChanged"] = function()
  child.tmpdir()
  child.edit("a.txt", { "" })
  child.clear_requests()
  child.cmd "doautocmd FocusLost"
  eq(child.event_types(), { "editorChanged" })
end

T["fileCreated"] = MiniTest.new_set { hooks = { pre_case = function() child.tmpdir() end } }

T["fileCreated"]["sent on the first write of a new file"] = function()
  child.edit "new.txt"
  eq(child.event_types(), { "activateFileChanged" })
  child.type_keys "ihello<Esc>"
  child.clear_requests()
  child.cmd "write"
  eq(child.event_types(), { "fileCreated", "fileSaved" })
  eq(last_event().operationType, "write")
  child.cmd "write"
  eq(child.event_types(), { "fileCreated", "fileSaved", "fileSaved" })
end

T["fileCreated"]["not for existing files"] = function()
  child.edit("old.txt", { "" })
  child.clear_requests()
  child.cmd "write"
  eq(child.event_types(), { "fileSaved" })
end

T["fileCreated"]["not when the new buffer is discarded"] = function()
  child.edit "new.txt"
  child.cmd "bwipeout!"
  child.edit("new.txt", { "" })
  child.clear_requests()
  child.cmd "write"
  eq(child.event_types(), { "fileSaved" })
end

return T
