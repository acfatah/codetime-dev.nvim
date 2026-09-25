local M = {
  value = nil,
  source = nil,
}

-- same file the codetime CLI and the Zed extension read
M.config_path = vim.fs.joinpath(vim.uv.os_homedir(), ".codetime", "config.json")

local function from_config_file()
  local ok, lines = pcall(vim.fn.readfile, M.config_path)
  if not ok then return nil end
  local decoded_ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok and type(data) == "table" and type(data.token) == "string" and data.token ~= "" then
    return data.token
  end
end

function M.load(opts_token)
  M.value, M.source = nil, nil
  if type(opts_token) == "string" and opts_token ~= "" then
    M.value, M.source = opts_token, "setup({ token })"
  elseif vim.env.CODETIME_TOKEN and vim.env.CODETIME_TOKEN ~= "" then
    M.value, M.source = vim.env.CODETIME_TOKEN, "$CODETIME_TOKEN"
  else
    local token = from_config_file()
    if token then M.value, M.source = token, M.config_path end
  end
  return M.value
end

function M.masked()
  if not M.value then return "(none)" end
  return "***" .. M.value:sub(-4)
end

return M
