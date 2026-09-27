# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

Unofficial Neovim client for codetime.dev (Neovim 0.10+, `curl` on `PATH`).
Pure Lua, no dependencies, no build step. README.md is the user-facing spec
(options, commands, event table, privacy, delivery) — keep it in sync with
behavior changes. `docs/vscode-parity.md` maps every event and payload field
to the official VS Code extension and lists deliberate divergences; the
plugin must keep sending the same event types and payload shape as VS Code.

## Commands

- Tests (mini.test, cloned into git-ignored `deps/` by `make deps`):
  `make test`; one file: `make test-file FILE=tests/test_events.lua`.
  Another Neovim: `make test NVIM_BIN=/path/to/nvim` (the variable is not
  `NVIM`: Neovim's terminal sets `$NVIM` to its socket). CI
  (`.github/workflows/test.yml`) runs Neovim 0.10.4 + stable and
  `stylua --check lua/ tests/`.
- Format: `make format` / `make format-check` (`stylua lua/ tests/`), using the
  repo's `.stylua.toml`: 2 spaces, width 120, double quotes,
  `call_parentheses = "None"` (`require "x"`), collapsed one-line functions.
  If `stylua` isn't on `PATH`, `npx -y @johnnymorganz/stylua-bin lua/ tests/`
  works without installing (or `:MasonInstall stylua`).
- Manual check: `python3 tests/mock_server.py /tmp/log.jsonl` prints a port;
  point `api_url` at `http://127.0.0.1:<port>` (prefix `/s/<code>` to force
  a status). Avoid hitting the real API unless asked — it writes to the
  user's codetime account.

## Tests

`tests/helpers.lua` gives each case a fresh child Neovim (`child.setup()`),
so module singletons never leak between cases. By default it stubs
`codetime_dev.http` with a recorder (`child.events()`, `child.requests()`,
`child.respond({ status, body })` queues responses), isolates `$HOME`,
captures `vim.notify` in `_G.notes`, and fakes the clock: cross a throttle
with `child.advance(ms)` instead of sleeping. `child.git_repo{ origin,
detached }` / `child.tmpdir()` create temp dirs and `cd` into them.
`test_http.lua` is the only file using real curl, against
`tests/mock_server.py`.

## Architecture

`lua/codetime_dev/`, all modules are singletons holding state on `M`:

- `init.lua` — `setup()`: config → autocmds → user commands → one
  `vim.uv` timer every `status_interval` that runs `tick()` =
  `client.flush()` + `status.refresh()`. `reload()` re-reads the token,
  clears the 401 pause, and ticks immediately.
- `events.lua` — autocmds → `track(buf, event_type)`. Builds the payload
  (field names/event names mirror codetime-vscode's `src/events.ts`; arch
  mapped to Node `os.arch()` names). Per-`event\0file` throttle, checked
  **before** `project.info()` because CursorMoved/TextChangedI fire
  constantly: `fileEdited`/`fileAddedLine` → `write_throttle`, cursor and
  scroll events → `cursor_throttle`, other writes none, other reads
  `read_throttle`. Per-buffer state: line counts (`fileAddedLine` = line
  count grew) and new-file marks (`fileCreated` on first write after
  `BufNewFile`), cleared on `BufWipeout`.
- `project.lua` — project = basename of `vim.fs.root(buf, ".git")` or cwd.
  Git origin/branch cached per root, always strings (`""` on failure,
  branch via `rev-parse --abbrev-ref HEAD`, like VS Code); fetched
  **synchronously** (2s cap) the first time a root is seen so the first
  event has git info, async on `FocusGained` refresh.
- `client.lua` — POST `/v3/users/event-log`. 2xx → `sent++`; 401 →
  `on_unauthorized()` pauses all sending (one warning) until
  `:CodeTimeDevReload`; status 0 or 5xx → in-memory queue (capped at
  `queue_limit`, oldest dropped); other 4xx → dropped, recorded in
  `last_error`.
- `status.lua` — GET `/v3/users/self/minutes?minutes=<since midnight>` for
  the statusline (`format_today()` / `today_minutes()`); shares the 401
  pause with `client`.
- `http.lua` — sole transport: `vim.system` curl. Token and JSON body go via
  `--config -` on **stdin**, never argv (keeps them out of `ps`); keep it
  that way. Callback gets `(status, body)`, `status == 0` meaning
  network/curl failure with stderr as body; always invoked via
  `vim.schedule`.
- `token.lua` — lookup order: `opts.token` → `$CODETIME_TOKEN` →
  `~/.codetime/config.json` (shared with codetime-cli and the Zed
  extension). Always show it via `masked()`.

## Gotchas

- Only named buffers with empty `buftype` are tracked (`project.info`
  returns nil otherwise).
- Queue is memory-only; lost on exit by design (documented in README).
- `plans/` is excluded via `.git/info/exclude` and holds local plan
  symlinks — never commit it.
