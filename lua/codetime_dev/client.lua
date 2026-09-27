local config = require "codetime_dev.config"
local http = require "codetime_dev.http"
local token = require "codetime_dev.token"

local M = {
  queue = {},
  paused = false, -- set on 401 until :CodeTimeDevReload
  last_error = nil,
  sent = 0,
}

local function enqueue(event)
  table.insert(M.queue, event)
  while #M.queue > config.options.queue_limit do
    table.remove(M.queue, 1)
  end
end

function M.on_unauthorized()
  if M.paused then return end
  M.paused = true
  M.last_error = "401 Unauthorized"
  vim.notify(
    "codetime.dev: token rejected ("
      .. token.masked()
      .. " from "
      .. tostring(token.source)
      .. "). "
      .. "Fix it, then :CodeTimeDevReload",
    vim.log.levels.WARN
  )
end

function M.send(event)
  if not token.value or M.paused then return end
  http.request("POST", "/v3/users/event-log", event, function(status, body)
    if status >= 200 and status < 300 then
      M.sent = M.sent + 1
    elseif status == 401 then
      M.on_unauthorized()
    elseif status == 0 or status >= 500 then
      -- network or server trouble: keep it for the next retry
      M.last_error = status == 0 and body or ("HTTP " .. status)
      enqueue(event)
    else
      M.last_error = "HTTP " .. status .. ": " .. body:sub(1, 200)
    end
  end)
end

function M.flush()
  if #M.queue == 0 or M.paused or not token.value then return end
  local pending = M.queue
  M.queue = {}
  for _, event in ipairs(pending) do
    M.send(event)
  end
end

return M
