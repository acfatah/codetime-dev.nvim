local H = require "tests.helpers"
local eq = H.eq

local child = H.new_child()
local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      child.setup()
      child.clear_requests()
    end,
    post_once = child.stop,
  },
}

local function send(event) child.lua([[require("codetime_dev.client").send(...)]], { event }) end
local function client(field) return child.lua_get([[require("codetime_dev.client")[...] ]], { field }) end
local function warnings()
  return child.lua_get [[vim.tbl_filter(function(n) return n.level == vim.log.levels.WARN end, _G.notes)]]
end

T["POSTs the event to /v3/users/event-log"] = function()
  send { n = 1 }
  eq(child.requests(), { { method = "POST", path = "/v3/users/event-log", body = { n = 1 } } })
  eq(client "sent", 1)
  eq(client "queue", {})
end

T["network failure is queued"] = function()
  child.respond { 0, "curl: (7) Failed to connect" }
  send { n = 1 }
  eq(client "queue", { { n = 1 } })
  eq(client "last_error", "curl: (7) Failed to connect")
  eq(client "sent", 0)
end

T["5xx is queued"] = function()
  child.respond { 503, "" }
  send { n = 1 }
  eq(client "queue", { { n = 1 } })
  eq(client "last_error", "HTTP 503")
end

T["other 4xx is dropped"] = function()
  child.respond { 400, "bad event" }
  send { n = 1 }
  eq(client "queue", {})
  eq(client "last_error", "HTTP 400: bad event")
end

T["queue keeps the newest queue_limit events"] = function()
  child.setup { setup = { queue_limit = 2 } }
  child.respond({ 0, "down" }, { 0, "down" }, { 0, "down" })
  send { n = 1 }
  send { n = 2 }
  send { n = 3 }
  eq(client "queue", { { n = 2 }, { n = 3 } })
end

T["flush resends queued events in order"] = function()
  child.respond({ 0, "down" }, { 0, "down" })
  send { n = 1 }
  send { n = 2 }
  child.clear_requests()
  child.lua [[require("codetime_dev.client").flush()]]
  eq(vim.tbl_map(function(r) return r.body end, child.requests()), { { n = 1 }, { n = 2 } })
  eq(client "queue", {})
  eq(client "sent", 2)
end

T["failed resend goes back to the queue"] = function()
  child.respond({ 0, "down" }, { 0, "still down" })
  send { n = 1 }
  child.lua [[require("codetime_dev.client").flush()]]
  eq(client "queue", { { n = 1 } })
end

T["no token: nothing is sent"] = function()
  child.setup { token = false }
  eq(child.requests(), {})
  eq(#warnings(), 1)
  H.eq(warnings()[1].msg:find("no token", 1, true) ~= nil, true)
  send { n = 1 }
  eq(child.requests(), {})
end

T["401"] = MiniTest.new_set()

T["401"]["warns once and pauses sending"] = function()
  child.respond { 401, "" }
  send { n = 1 }
  eq(client "paused", true)
  eq(client "last_error", "401 Unauthorized")
  eq(#warnings(), 1)
  H.eq(warnings()[1].msg:find("***test", 1, true) ~= nil, true) -- masked token

  send { n = 2 }
  child.lua [[require("codetime_dev.status").refresh()]]
  eq(#child.requests(), 1)
  eq(#warnings(), 1)
end

T["401"]["event is not queued"] = function()
  child.respond { 401, "" }
  send { n = 1 }
  eq(client "queue", {})
end

T["401"]["flush does nothing while paused"] = function()
  child.respond({ 0, "down" }, { 401, "" })
  send { n = 1 }
  send { n = 2 }
  child.clear_requests()
  child.lua [[require("codetime_dev.client").flush()]]
  eq(child.requests(), {})
  eq(client "queue", { { n = 1 } })
end

T["401"][":CodeTimeDevReload resumes and flushes"] = function()
  child.respond({ 0, "down" }, { 401, "" })
  send { n = 1 }
  send { n = 2 }
  child.clear_requests()
  child.cmd "CodeTimeDevReload"
  eq(client "paused", false)
  eq(client "last_error", vim.NIL)
  eq(child.requests()[1].body, { n = 1 })
  eq(child.requests()[2].method, "GET")
end

return T
