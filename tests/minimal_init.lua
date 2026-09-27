-- Used both by the test runner (`make test`) and by every child Neovim.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/deps/mini.nvim")
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

require("mini.test").setup()
