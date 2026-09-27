local H = require "tests.helpers"
local eq = H.eq

local child = H.new_child { setup = false, token = false }
local T = MiniTest.new_set { hooks = { pre_case = child.setup, post_once = child.stop } }

local function write_config(content)
  child.lua(
    [[
    local token = require "codetime_dev.token"
    vim.fn.mkdir(vim.fs.dirname(token.config_path), "p")
    vim.fn.writefile({ ... }, token.config_path)
  ]],
    { content }
  )
end

local function load(opts_token)
  return child.lua_get(
    [[(function(t)
      local token = require "codetime_dev.token"
      token.load(t)
      return { value = token.value or vim.NIL, source = token.source or vim.NIL }
    end)(...)]],
    { opts_token }
  )
end

T["config file is ~/.codetime/config.json"] = function()
  local home = child.lua_get "vim.env.HOME"
  eq(child.lua_get [[require("codetime_dev.token").config_path]], home .. "/.codetime/config.json")
end

T["lookup order"] = MiniTest.new_set()

T["lookup order"]["setup token wins"] = function()
  child.lua [[vim.env.CODETIME_TOKEN = "from-env"]]
  write_config [[{ "token": "from-file" }]]
  eq(load "from-opts", { value = "from-opts", source = "setup({ token })" })
end

T["lookup order"]["then $CODETIME_TOKEN"] = function()
  child.lua [[vim.env.CODETIME_TOKEN = "from-env"]]
  write_config [[{ "token": "from-file" }]]
  eq(load(), { value = "from-env", source = "$CODETIME_TOKEN" })
end

T["lookup order"]["then config file"] = function()
  write_config [[{ "token": "from-file" }]]
  local path = child.lua_get [[require("codetime_dev.token").config_path]]
  eq(load(), { value = "from-file", source = path })
end

T["lookup order"]["empty values are skipped"] = function()
  child.lua [[vim.env.CODETIME_TOKEN = ""]]
  write_config [[{ "token": "from-file" }]]
  eq(load "", { value = "from-file", source = child.lua_get [[require("codetime_dev.token").config_path]] })
end

T["missing or malformed config gives no token"] = function()
  eq(load(), { value = vim.NIL, source = vim.NIL })
  write_config "{ not json"
  eq(load(), { value = vim.NIL, source = vim.NIL })
  write_config [[{ "token": "" }]]
  eq(load(), { value = vim.NIL, source = vim.NIL })
end

T["masked shows only the last 4 characters"] = function()
  eq(child.lua_get [[require("codetime_dev.token").masked()]], "(none)")
  load "abcdef123456"
  eq(child.lua_get [[require("codetime_dev.token").masked()]], "***3456")
end

return T
