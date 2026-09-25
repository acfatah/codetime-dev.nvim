local client = require "codetime_dev.client"
local config = require "codetime_dev.config"
local events = require "codetime_dev.events"
local status = require "codetime_dev.status"
local token = require "codetime_dev.token"

local M = {}

local timer = nil

local function tick()
  client.flush()
  status.refresh()
end

function M.reload()
  token.load(config.options.token)
  client.paused = false
  client.last_error = nil
  if not token.value then
    vim.notify(
      "codetime.dev: no token (setup({ token }), $CODETIME_TOKEN or " .. token.config_path .. ")",
      vim.log.levels.WARN
    )
  end
  tick()
end

function M.print_status()
  local lines = {
    "codetime.dev",
    "  token:      " .. token.masked() .. " (" .. (token.source or "not found") .. ")",
    "  api:        " .. config.options.api_url,
    "  sending:    " .. (client.paused and "paused (401)" or token.value and "on" or "off (no token)"),
    "  sent:       " .. client.sent .. " events this session",
    "  queued:     " .. #client.queue,
    "  last error: " .. (client.last_error or "none"),
    "  today:      " .. (M.format_today() or "unknown"),
  }
  vim.api.nvim_echo({ { table.concat(lines, "\n") } }, false, {})
end

-- minutes today from the dashboard (all editors and machines), nil until fetched
function M.today_minutes() return status.today end

-- "1h 23m" / "12m", nil until fetched
function M.format_today() return status.format(status.today) end

function M.setup(opts)
  config.setup(opts)
  events.setup()

  vim.api.nvim_create_user_command("CodeTimeDevStatus", M.print_status, {})
  vim.api.nvim_create_user_command("CodeTimeDevReload", M.reload, {})
  vim.api.nvim_create_user_command(
    "CodeTimeDevDashboard",
    function() vim.ui.open "https://codetime.dev/dashboard" end,
    {}
  )

  if timer then timer:stop() end
  timer = vim.uv.new_timer()
  timer:start(config.options.status_interval, config.options.status_interval, vim.schedule_wrap(tick))

  M.reload()
end

return M
