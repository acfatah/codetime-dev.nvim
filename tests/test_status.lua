local H = require "tests.helpers"
local eq = H.eq

local child = H.new_child()
local T = MiniTest.new_set { hooks = { pre_case = child.setup, post_once = child.stop } }

local function today() return child.lua_get [[require("codetime_dev").today_minutes()]] end
local function refresh(...)
  child.clear_requests()
  child.respond(...)
  child.lua [[require("codetime_dev.status").refresh()]]
end

T["setup fetches minutes since local midnight"] = function()
  local request = child.requests()[1]
  eq(request.method, "GET")
  local minutes = tonumber(request.path:match "^/v3/users/self/minutes%?minutes=(%d+)$")
  local expected = child.lua_get [[(function() local t = os.date "*t"; return t.hour * 60 + t.min end)()]]
  H.eq(minutes ~= nil and math.abs(minutes - math.max(expected, 1)) <= 1, true)
end

T["200 sets today's minutes"] = function()
  refresh { 200, '{"minutes":83}' }
  eq(today(), 83)
  eq(child.lua_get [[require("codetime_dev").format_today()]], "1h 23m")
end

T["unknown until fetched"] = function()
  eq(today(), vim.NIL)
  eq(child.lua_get [[require("codetime_dev").format_today()]], vim.NIL)
end

T["bad body is ignored"] = function()
  refresh { 200, '{"minutes":83}' }
  refresh { 200, "not json" }
  refresh { 200, '{"minutes":"83"}' }
  eq(today(), 83)
end

T["401 pauses like the event POST"] = function()
  refresh { 401, "" }
  eq(child.lua_get [[require("codetime_dev.client").paused]], true)
end

T["other failures are reported"] = function()
  refresh { 500, "" }
  eq(child.lua_get [[require("codetime_dev.client").last_error]], "HTTP 500")
  refresh { 0, "curl: (28) timeout" }
  eq(child.lua_get [[require("codetime_dev.client").last_error]], "curl: (28) timeout")
end

T["no token: no request"] = function()
  child.setup { token = false }
  eq(child.requests(), {})
end

T["format"] = function()
  local function format(m) return child.lua_get([[require("codetime_dev.status").format(...)]], { m }) end
  eq(format(nil), vim.NIL)
  eq(format(0), "0m")
  eq(format(12), "12m")
  eq(format(60), "1h 00m")
  eq(format(65), "1h 05m")
  eq(format(83.9), "1h 23m")
  eq(format(1500), "25h 00m")
end

return T
