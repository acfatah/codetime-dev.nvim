local H = require "tests.helpers"
local eq = H.eq

local child = H.new_child { setup = false }
local T = MiniTest.new_set { hooks = { pre_case = child.setup, post_once = child.stop } }

T["defaults"] = function()
  child.lua [[require("codetime_dev.config").setup()]]
  eq(child.lua_get [[require("codetime_dev.config").options]], {
    api_url = "https://api.codetime.dev",
    editor = "Neovim",
    read_throttle = 120000,
    write_throttle = 10000,
    status_interval = 60000,
    queue_limit = 500,
  })
end

T["merges user options over defaults"] = function()
  child.lua [[require("codetime_dev.config").setup({ editor = "Nvim", queue_limit = 5 })]]
  local options = child.lua_get [[require("codetime_dev.config").options]]
  eq(options.editor, "Nvim")
  eq(options.queue_limit, 5)
  eq(options.read_throttle, 120000)
end

T["setup again starts from defaults"] = function()
  child.lua [[require("codetime_dev.config").setup({ editor = "Nvim" })]]
  child.lua [[require("codetime_dev.config").setup({ queue_limit = 5 })]]
  eq(child.lua_get [[require("codetime_dev.config").options.editor]], "Neovim")
end

return T
