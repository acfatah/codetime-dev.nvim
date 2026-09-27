local Helpers = {}

Helpers.eq = MiniTest.expect.equality
Helpers.neq = MiniTest.expect.no_equality

Helpers.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- Runs inside the child before the plugin loads: isolated $HOME (so a real
-- ~/.codetime/config.json is never read), captured notifications and a
-- controllable clock (`_G.now_ms`) so throttles can be crossed without sleeping.
local prepare = [[
  local opts = ...
  local home = vim.fn.tempname()
  vim.fn.mkdir(home, "p")
  vim.env.HOME = home
  vim.env.CODETIME_TOKEN = opts.token or nil

  _G.notes = {}
  vim.notify = function(msg, level) table.insert(_G.notes, { msg = msg, level = level }) end

  _G.now_ms = 1700000000000
  vim.uv.gettimeofday = function() return math.floor(_G.now_ms / 1000), (_G.now_ms % 1000) * 1000 end

  if opts.stub_http then
    -- records every request; answers from `_G.responses` ({ status, body }), else 200
    _G.requests, _G.responses = {}, {}
    package.loaded["codetime_dev.http"] = {
      request = function(method, path, body, callback)
        table.insert(_G.requests, { method = method, path = path, body = body })
        local response = table.remove(_G.responses, 1) or { 200, "" }
        callback(response[1], response[2])
      end,
    }
  end

  if opts.setup then require("codetime_dev").setup(opts.setup) end
]]

---@class Child
---@param defaults? table options merged into every `child.setup()`
function Helpers.new_child(defaults)
  local child = MiniTest.new_child_neovim()

  --- Restart the child and load the plugin.
  ---@param opts? { token?: string|false, stub_http?: boolean, setup?: table|false }
  function child.setup(opts)
    opts = vim.tbl_extend("force", { token = "test", stub_http = true, setup = {} }, defaults or {}, opts or {})
    if opts.token == false then opts.token = nil end
    child.restart { "-u", Helpers.root .. "/tests/minimal_init.lua" }
    child.lua(prepare, { opts })
  end

  function child.requests() return child.lua_get "_G.requests" end

  --- bodies of every event-log POST so far
  function child.events()
    return child.lua_get [[vim.iter(_G.requests)
      :filter(function(r) return r.path == "/v3/users/event-log" end)
      :map(function(r) return r.body end)
      :totable()]]
  end

  function child.event_types()
    return vim.tbl_map(function(e) return e.eventType end, child.events())
  end

  function child.clear_requests() child.lua "_G.requests = {}" end

  --- queue HTTP responses for the stub, e.g. `child.respond({ 401, "" })`
  function child.respond(...) child.lua("vim.list_extend(_G.responses, { ... })", { ... }) end

  function child.advance(ms) child.lua("_G.now_ms = _G.now_ms + ...", { ms }) end

  --- new empty directory, made the child's cwd
  function child.tmpdir()
    return child.lua_get [[(function()
      local dir = vim.fn.resolve(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      vim.fn.chdir(dir)
      return dir
    end)()]]
  end

  --- git repo in a new temp dir, made the child's cwd
  ---@param opts? { origin?: string, branch?: string, detached?: boolean }
  function child.git_repo(opts)
    opts = opts or {}
    local dir = child.tmpdir()
    local function git(...)
      local res = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
      assert(res.code == 0, res.stderr)
    end
    git("init", "-q", "-b", opts.branch or "main")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
    if opts.origin then git("remote", "add", "origin", opts.origin) end
    if opts.detached then git("checkout", "-q", "--detach") end
    return dir
  end

  --- write `lines` to `path` (relative to child cwd) and :edit it
  function child.edit(path, lines)
    child.lua(
      [[
      local path, lines = ...
      if lines then
        vim.fn.mkdir(vim.fs.dirname(vim.fn.fnamemodify(path, ":p")), "p")
        vim.fn.writefile(lines, path)
      end
      vim.cmd.edit(vim.fn.fnameescape(path))
    ]],
      { path, lines }
    )
  end

  return child
end

return Helpers
