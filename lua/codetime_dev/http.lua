local config = require "codetime_dev.config"
local token = require "codetime_dev.token"

local M = {}

-- value for a curl config file: double-quoted, backslash-escaped
local function quote(value) return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end

---@param method "GET"|"POST"
---@param path string
---@param body table|nil
---@param callback fun(status: integer, body: string) status 0 = network/curl failure
function M.request(method, path, body, callback)
  -- token and payload go through stdin (--config -), never argv, so they don't show up in `ps`
  local lines = {
    "header = " .. quote("Authorization: Bearer " .. (token.value or "")),
    "header = " .. quote "User-Agent: CodeTime Client",
  }
  if body then
    table.insert(lines, "header = " .. quote "Content-Type: application/json")
    table.insert(lines, "data-binary = " .. quote(vim.json.encode(body)))
  end

  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time",
    "30",
    "--request",
    method,
    "--write-out",
    "\n%{http_code}",
    "--config",
    "-",
    config.options.api_url .. path,
  }
  local ok, err = pcall(vim.system, cmd, { text = true, stdin = table.concat(lines, "\n") .. "\n" }, function(res)
    local out = res.stdout or ""
    local response, code = out:match "^(.*)\n(%d+)$"
    local status = res.code == 0 and tonumber(code) or 0
    -- on curl failure the reason is on stderr, e.g. "curl: (7) Failed to connect ..."
    local text = status == 0 and vim.trim(res.stderr or "") or (response or out)
    vim.schedule(function() callback(status, text) end)
  end)
  if not ok then vim.schedule(function() callback(0, tostring(err)) end) end
end

return M
