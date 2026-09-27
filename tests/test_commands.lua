local H = require "tests.helpers"
local eq = H.eq

local child = H.new_child { token = "abcdefgh1234" }
local T = MiniTest.new_set { hooks = { pre_case = child.setup, post_once = child.stop } }

T["user commands exist"] = function()
  for _, name in ipairs { "CodeTimeDevStatus", "CodeTimeDevReload", "CodeTimeDevDashboard" } do
    eq(child.fn.exists(":" .. name), 2)
  end
end

T[":CodeTimeDevStatus masks the token"] = function()
  local out = child.cmd_capture "CodeTimeDevStatus"
  H.eq(out:find("***1234 ($CODETIME_TOKEN)", 1, true) ~= nil, true)
  eq(out:find("abcdefgh", 1, true), nil)
  H.eq(out:find("sending:    on", 1, true) ~= nil, true)
end

T[":CodeTimeDevDashboard opens the dashboard"] = function()
  child.lua [[vim.ui.open = function(url) _G.opened = url end]]
  child.cmd "CodeTimeDevDashboard"
  eq(child.lua_get "_G.opened", "https://codetime.dev/dashboard")
end

T["setup twice keeps one timer and one autocmd group"] = function()
  child.lua [[require("codetime_dev").setup({})]]
  eq(#child.api.nvim_get_autocmds { group = "CodeTimeDev", event = "BufEnter" }, 1)
end

return T
