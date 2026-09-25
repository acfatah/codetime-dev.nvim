local client = require "codetime_dev.client"
local config = require "codetime_dev.config"
local project = require "codetime_dev.project"

local M = {}

-- event names match codetime-vscode's src/events.ts
M.ACTIVATE_FILE_CHANGED = "activateFileChanged"
M.EDITOR_CHANGED = "editorChanged"
M.FILE_CREATED = "fileCreated"
M.FILE_EDITED = "fileEdited"
M.FILE_SAVED = "fileSaved"

local write_events = {
  [M.FILE_CREATED] = true,
  [M.FILE_EDITED] = true,
  [M.FILE_SAVED] = true,
}

-- Node's os.arch() names, which the other CodeTime clients send
local arch_names = { x86_64 = "x64", amd64 = "x64", aarch64 = "arm64", armv7l = "arm", i686 = "ia32" }

local uname = vim.uv.os_uname()
local platform = uname.sysname .. " " .. uname.release
local platform_arch = arch_names[uname.machine] or uname.machine

-- "<event>\0<file>" -> last sent (ms)
local last_sent = {}

local function now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local function throttle_ms(event_type)
  if event_type == M.FILE_EDITED then return config.options.write_throttle end
  if write_events[event_type] then return 0 end
  return config.options.read_throttle
end

function M.track(buf, event_type)
  local info = project.info(buf)
  if not info then return end

  local time = now_ms()
  local key = event_type .. "\0" .. info.absolute
  local wait = throttle_ms(event_type)
  if wait > 0 and last_sent[key] and time - last_sent[key] < wait then return end
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

function M.setup()
  local group = vim.api.nvim_create_augroup("CodeTimeDev", { clear = true })
  local function on(events, event_type, extra)
    vim.api.nvim_create_autocmd(events, {
      group = group,
      callback = function(args)
        if extra then extra() end
        M.track(args.buf, event_type)
      end,
    })
  end
  on("BufEnter", M.ACTIVATE_FILE_CHANGED)
  on("FocusGained", M.EDITOR_CHANGED, project.refresh_all_git) -- branch may have changed outside
  on({ "TextChanged", "TextChangedI" }, M.FILE_EDITED)
  on("BufWritePost", M.FILE_SAVED)
  on("BufNewFile", M.FILE_CREATED)
end

return M
