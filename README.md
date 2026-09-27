# codetime-dev.nvim

Unofficial [codetime.dev](https://codetime.dev) client for Neovim. Sends
editor activity to your codetime.dev dashboard, the same way the official
[VS Code](https://github.com/codetime-dev/codetime-vscode) and
[Zed](https://github.com/codetime-dev/codetime-zed) clients do, and shows
today's coding time from the dashboard.

## Requirements

- Neovim 0.10+
- `curl` on `PATH`
- A codetime.dev upload token (dashboard → settings)

## Install (lazy.nvim)

```lua
{
  "acfatah/codetime-dev.nvim",
  event = "VeryLazy",
  opts = {},
}
```

## Token

Looked up in this order:

1. `opts.token`
2. `$CODETIME_TOKEN`
3. `~/.codetime/config.json` (`{ "token": "..." }`), written by
   [codetime-cli](https://github.com/codetime-dev/codetime-cli)
   (`codetime token set <token>`) and read by the Zed extension

Prefer 2 or 3 so the token never lands in your dotfiles. The token is
passed to `curl` on stdin, not as an argument, so it does not show up in
`ps`.

## Options

Defaults:

```lua
opts = {
  api_url = "https://api.codetime.dev",
  editor = "Neovim",
  token = nil,
  read_throttle = 120000, -- ms between read events for the same file
  write_throttle = 10000, -- ms between edit events for the same file
  cursor_throttle = 30000, -- ms between cursor/scroll events for the same file
  status_interval = 60000, -- ms between dashboard refreshes / retries
  queue_limit = 500, -- failed events kept for retry
}
```

## Commands

| Command | Action |
|---|---|
| `:CodeTimeDevStatus` | token source (masked), sent/queued counts, last error, today |
| `:CodeTimeDevDashboard` | open https://codetime.dev/dashboard |
| `:CodeTimeDevReload` | re-read the token and resume after a 401 |

## Statusline

```lua
require("codetime_dev").format_today() -- "1h 23m", nil until fetched
require("codetime_dev").today_minutes() -- 83, nil until fetched
```

Today's minutes come from the dashboard (all editors and machines) and
refresh every `status_interval`.

lualine:

```lua
lualine_x = {
  function() return "󱑎 " .. (require("codetime_dev").format_today() or "-") end,
},
```

## Events

| Neovim event | codetime event | Type | Throttle |
|---|---|---|---|
| `BufEnter` | `activateFileChanged` | read | `read_throttle` per file |
| `FocusGained`, `FocusLost` | `editorChanged` | read | `read_throttle` per file |
| `CursorMoved` | `changeEditorSelection` | read | `cursor_throttle` per file |
| `WinScrolled` | `changeEditorVisibleRanges` | read | `cursor_throttle` per file |
| `TextChanged`, `TextChangedI` | `fileEdited` | write | `write_throttle` per file |
| same, when lines were added | `fileAddedLine` | write | `write_throttle` per file |
| `BufWritePost` | `fileSaved` | write | none |
| first `BufWritePost` after `BufNewFile` | `fileCreated` | write | none |

Only real file buffers are tracked (named, `buftype` empty).
`FocusGained` / `FocusLost` need a terminal that reports focus changes
(in tmux: `set -g focus-events on`).

## Compatibility with VS Code

Events and payload fields follow the official VS Code extension. See
[docs/vscode-parity.md](docs/vscode-parity.md) for the mapping and the
deliberate differences (throttling instead of random sampling, retry
queue, 401 pause).

## Development

```sh
make test                                  # mini.test, cloned into deps/
make test-file FILE=tests/test_events.lua  # one file
make format                                # stylua lua/ tests/
```

## Privacy

Each event sends the same fields as the VS Code extension:
project (git root or cwd folder name), language (filetype), relative
and **absolute** file path, editor, OS name/release, architecture,
event time/type, read/write, git `origin` URL and current branch
(`""` outside a repo or without a remote, `"HEAD"` when detached). No
file contents are sent.

## Delivery

Failed requests (network error, 5xx) are queued in memory and retried
every `status_interval`. A 401 pauses sending with one warning until
`:CodeTimeDevReload`. Queued events are lost when Neovim exits.

## License

MIT
