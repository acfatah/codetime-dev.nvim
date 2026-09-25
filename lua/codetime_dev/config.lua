local M = {}

M.defaults = {
  api_url = "https://api.codetime.dev",
  editor = "Neovim",
  token = nil, -- falls back to $CODETIME_TOKEN, then ~/.codetime/config.json
  read_throttle = 120000, -- ms between read events for the same file
  write_throttle = 10000, -- ms between edit events for the same file
  status_interval = 60000, -- ms between dashboard minute refreshes / queue retries
  queue_limit = 500, -- failed events kept for retry, oldest dropped first
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts) M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {}) end

return M
