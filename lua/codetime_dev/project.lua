local M = {}

-- root -> { origin = string|nil, branch = string|nil }
local git_cache = {}

local function parse(res)
  local value = res.code == 0 and vim.trim(res.stdout or "") or ""
  return value ~= "" and value or nil
end

local function git_output(root, args, sync, callback)
  local cmd = vim.list_extend({ "git", "-C", root }, args)
  if sync then return callback(parse(vim.system(cmd, { text = true }):wait(2000))) end
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function() callback(parse(res)) end)
  end)
end

-- sync on first sight of a repo so its first event carries git info; async refreshes after
function M.refresh_git(root, sync)
  if not vim.uv.fs_stat(vim.fs.joinpath(root, ".git")) then return end
  local entry = git_cache[root] or {}
  git_cache[root] = entry
  git_output(root, { "remote", "get-url", "origin" }, sync, function(origin) entry.origin = origin end)
  git_output(root, { "branch", "--show-current" }, sync, function(branch) entry.branch = branch end)
end

function M.refresh_all_git()
  for root in pairs(git_cache) do
    M.refresh_git(root)
  end
end

---@return { project: string, root: string, absolute: string, relative: string, git_origin: string|nil, git_branch: string|nil }|nil
function M.info(buf)
  local absolute = vim.api.nvim_buf_get_name(buf)
  if absolute == "" or vim.bo[buf].buftype ~= "" then return nil end

  local root = vim.fs.root(buf, ".git") or vim.fn.getcwd()
  local relative = "[other workspace]" -- same marker the VS Code extension uses
  if vim.startswith(absolute, root .. "/") then relative = absolute:sub(#root + 2) end

  if not git_cache[root] then M.refresh_git(root, true) end
  local git = git_cache[root] or {}
  return {
    project = vim.fs.basename(root),
    root = root,
    absolute = absolute,
    relative = relative,
    git_origin = git.origin,
    git_branch = git.branch,
  }
end

return M
