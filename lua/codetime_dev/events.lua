local client = require "codetime_dev.client"
local config = require "codetime_dev.config"
local project = require "codetime_dev.project"

local M = {}

-- event names match codetime-vscode's src/events.ts
M.ACTIVATE_FILE_CHANGED = "activateFileChanged"
M.CHANGE_EDITOR_SELECTION = "changeEditorSelection"
M.CHANGE_EDITOR_VISIBLE_RANGES = "changeEditorVisibleRanges"
M.EDITOR_CHANGED = "editorChanged"
M.FILE_ADDED_LINE = "fileAddedLine"
M.FILE_CREATED = "fileCreated"
M.FILE_EDITED = "fileEdited"
M.FILE_REMOVED = "fileRemoved" -- defined but never sent, as in VS Code
M.FILE_SAVED = "fileSaved"

-- operationType "write" (VS Code getOperationType); everything else is "read"
local write_events = {
  [M.FILE_ADDED_LINE] = true,
  [M.FILE_CREATED] = true,
  [M.FILE_EDITED] = true,
  [M.FILE_REMOVED] = true,
  [M.FILE_SAVED] = true,
}

-- Node's os.arch() names, which the other CodeTime clients send
local arch_names = { x86_64 = "x64", amd64 = "x64", aarch64 = "arm64", armv7l = "arm", i686 = "ia32" }

local uname = vim.uv.os_uname()
local platform = uname.sysname .. " " .. uname.release
local platform_arch = arch_names[uname.machine] or uname.machine

-- "<event>\0<file>" -> last sent (ms)
local last_sent = {}
-- buf -> line count after the last change, to tell fileAddedLine from fileEdited
local line_counts = {}
-- buf -> true for a new file (BufNewFile) not yet written
local new_files = {}

local function now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local function throttle_ms(event_type)
  if event_type == M.FILE_EDITED or event_type == M.FILE_ADDED_LINE then return config.options.write_throttle end
  if event_type == M.CHANGE_EDITOR_SELECTION or event_type == M.CHANGE_EDITOR_VISIBLE_RANGES then
    return config.options.cursor_throttle
  end
  if write_events[event_type] then return 0 end
  return config.options.read_throttle
end

function M.track(buf, event_type)
  -- cheap checks first: this runs on every keystroke and cursor motion
  local absolute = vim.api.nvim_buf_get_name(buf)
  if absolute == "" or vim.bo[buf].buftype ~= "" then return end

  local time = now_ms()
  local key = event_type .. "\0" .. absolute
  local wait = throttle_ms(event_type)
  if wait > 0 and last_sent[key] and time - last_sent[key] < wait then return end

  local info = project.info(buf)
  if not info then return end
  last_sent[key] = time

  client.send {
    project = info.project,
    language = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype or "plaintext",
    relativeFile = info.relative,
    absoluteFile = info.absolute,
    editor = config.options.editor,
    platform = platform,
    eventTime = time,
    eventType = event_type,
    platformArch = platform_arch,
    gitOrigin = info.git_origin,
    gitBranch = info.git_branch,
    operationType = write_events[event_type] and "write" or "read",
  }
end

local function on_change(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local before = line_counts[buf]
  line_counts[buf] = count
  M.track(buf, before and count > before and M.FILE_ADDED_LINE or M.FILE_EDITED)
end

local function on_write(buf)
  if new_files[buf] then
    new_files[buf] = nil
    M.track(buf, M.FILE_CREATED)
  end
  M.track(buf, M.FILE_SAVED)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("CodeTimeDev", { clear = true })
  local function on(events, callback) vim.api.nvim_create_autocmd(events, { group = group, callback = callback }) end
  local function send(event_type)
    return function(args) M.track(args.buf, event_type) end
  end

  on({ "BufReadPost", "BufNewFile" }, function(args) line_counts[args.buf] = vim.api.nvim_buf_line_count(args.buf) end)
  on("BufEnter", send(M.ACTIVATE_FILE_CHANGED))
  on("FocusGained", function(args)
    project.refresh_all_git() -- branch may have changed outside
    M.track(args.buf, M.EDITOR_CHANGED)
  end)
  on("FocusLost", send(M.EDITOR_CHANGED))
  on({ "TextChanged", "TextChangedI" }, function(args) on_change(args.buf) end)
  on("CursorMoved", send(M.CHANGE_EDITOR_SELECTION))
  on("WinScrolled", function(args)
    local win = tonumber(args.match)
    if win and vim.api.nvim_win_is_valid(win) then
      M.track(vim.api.nvim_win_get_buf(win), M.CHANGE_EDITOR_VISIBLE_RANGES)
    end
  end)
  -- fileCreated is sent on the first write, when the file actually exists
  on("BufNewFile", function(args) new_files[args.buf] = true end)
  on("BufWritePost", function(args) on_write(args.buf) end)
  on("BufWipeout", function(args)
    line_counts[args.buf], new_files[args.buf] = nil, nil
  end)
end

return M
