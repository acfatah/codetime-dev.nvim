-- Real curl against tests/mock_server.py: headers, body encoding, status
-- handling and keeping the token out of the process list.
local H = require "tests.helpers"
local eq = H.eq

local TOKEN = "s3cr3t-token-9876"
local log_file = vim.fn.tempname()
local server, port

local child = H.new_child { stub_http = false, token = false, setup = false }

local function received()
  local ok, lines = pcall(vim.fn.readfile, log_file)
  return vim.tbl_map(vim.json.decode, ok and lines or {})
end

local function start(path)
  vim.fn.writefile({}, log_file)
  child.setup()
  -- record what curl is started with
  child.lua [[
    _G.spawned = {}
    local system = vim.system
    vim.system = function(cmd, opts, on_exit)
      table.insert(_G.spawned, { cmd = cmd, stdin = opts and opts.stdin })
      return system(cmd, opts, on_exit)
    end
  ]]
  child.lua([[require("codetime_dev").setup(...)]], {
    { token = TOKEN, api_url = "http://127.0.0.1:" .. (path or port) },
  })
end

-- wait in the child until `expr` is truthy (curl runs asynchronously)
local function wait_for(expr) eq(child.lua_get("vim.wait(5000, function() return " .. expr .. " end, 10)"), true) end

local function client(field) return child.lua_get([[require("codetime_dev.client")[...] ]], { field }) end

local T = MiniTest.new_set {
  hooks = {
    pre_once = function()
      server = vim.system({ "python3", H.root .. "/tests/mock_server.py", log_file }, {
        stdout = function(_, data)
          if data and not port then port = tonumber(data:match "%d+") end
        end,
      })
      assert(vim.wait(5000, function() return port ~= nil end, 10), "mock server did not start")
    end,
    post_once = function()
      child.stop()
      server:kill(15)
      vim.fn.delete(log_file)
    end,
  },
}

T["GET minutes with auth headers"] = function()
  start()
  wait_for [[require("codetime_dev").today_minutes() == 42]]
  local request = received()[1]
  eq(request.method, "GET")
  H.eq(request.path:match "^/v3/users/self/minutes%?minutes=%d+$" ~= nil, true)
  eq(request.headers["Authorization"], "Bearer " .. TOKEN)
  eq(request.headers["User-Agent"], "CodeTime Client")
end

T["POST event as JSON"] = function()
  start()
  wait_for [[require("codetime_dev").today_minutes() ~= nil]]
  local event = { project = 'quote " and \\ backslash', eventTime = 1700000000000, gitOrigin = "" }
  child.lua([[require("codetime_dev.client").send(...)]], { event })
  wait_for [[require("codetime_dev.client").sent == 1]]

  local request = received()[2]
  eq(request.method, "POST")
  eq(request.path, "/v3/users/event-log")
  eq(request.headers["Content-Type"], "application/json")
  eq(request.headers["Authorization"], "Bearer " .. TOKEN)
  eq(request.headers["User-Agent"], "CodeTime Client")
  eq(vim.json.decode(request.body), event)
end

T["token and body go through stdin, not argv"] = function()
  start()
  child.lua [[require("codetime_dev.client").send({ secret_marker = "body-only" })]]
  wait_for [[require("codetime_dev.client").sent == 1]]
  local spawned = child.lua_get "_G.spawned"
  eq(#spawned, 2)
  for _, run in ipairs(spawned) do
    eq(run.cmd[1], "curl")
    for _, arg in ipairs(run.cmd) do
      eq(arg:find(TOKEN, 1, true), nil)
      eq(arg:find("body-only", 1, true), nil)
    end
    H.eq(run.stdin:find(TOKEN, 1, true) ~= nil, true)
  end
  H.eq(spawned[2].stdin:find("body-only", 1, true) ~= nil, true)
end

T["401 pauses sending"] = function()
  start(port .. "/s/401")
  wait_for [[require("codetime_dev.client").paused]]
  eq(client "last_error", "401 Unauthorized")
end

T["5xx queues the event"] = function()
  start(port .. "/s/502")
  child.lua [[require("codetime_dev.client").send({ n = 1 })]]
  wait_for [[#require("codetime_dev.client").queue == 1]]
  eq(client "last_error", "HTTP 502")
end

T["server down: status 0 with curl's error"] = function()
  start "1" -- nothing listens on port 1
  child.lua [[require("codetime_dev.client").send({ n = 1 })]]
  wait_for [[#require("codetime_dev.client").queue == 1]]
  H.eq(client("last_error"):match "^curl: %(7%)" ~= nil, true)
end

return T
