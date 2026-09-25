local client = require "codetime_dev.client"
local http = require "codetime_dev.http"
local token = require "codetime_dev.token"

local M = {
  today = nil, -- minutes today across all editors/machines, nil until fetched
  updated_at = nil,
}

local function minutes_since_midnight()
  local now = os.date "*t"
  return math.max(now.hour * 60 + now.min, 1)
end

function M.refresh()
  if not token.value or client.paused then return end
  http.request("GET", "/v3/users/self/minutes?minutes=" .. minutes_since_midnight(), nil, function(status, body)
    if status == 200 then
      local ok, data = pcall(vim.json.decode, body)
      if ok and type(data) == "table" and type(data.minutes) == "number" then
        M.today, M.updated_at = data.minutes, os.time()
        vim.cmd.redrawstatus()
      end
    elseif status == 401 then
      client.on_unauthorized()
    else
      client.last_error = status == 0 and body or ("HTTP " .. status)
    end
  end)
end

function M.format(minutes)
  if not minutes then return nil end
  local hours, mins = math.floor(minutes / 60), math.floor(minutes % 60)
  if hours > 0 then return string.format("%dh %02dm", hours, mins) end
  return string.format("%dm", mins)
end

return M
