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
  eq(child.event_types(), { "fileEdited" })
  eq(last_event().operationType, "write")
end

T["autocmds"]["insert-mode change sends fileEdited"] = function()
  child.type_keys("A", "!")
  eq(child.event_types(), { "fileEdited" })
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
  eq(#child.events(), 1)
  child.advance(10000)
  child.type_keys "x"
  eq(#child.events(), 2)
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

return T
