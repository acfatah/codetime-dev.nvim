# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

Unofficial Neovim client for codetime.dev (Neovim 0.10+, `curl` on `PATH`).
Pure Lua, no dependencies, no build step. README.md is the user-facing spec
(options, commands, event table, privacy, delivery) — keep it in sync with
behavior changes.

## Commands

No test suite, linter config, or CI in the repo.

- Format: `stylua lua/` (check only: `stylua --check lua/`), using the
  repo's `.stylua.toml`: 2 spaces, width 120, double quotes,
  `call_parentheses = "None"` (`require "x"`), collapsed one-line functions.
  If `stylua` isn't on `PATH`, `npx -y @johnnymorganz/stylua-bin lua/`
  works without installing (or `:MasonInstall stylua`).
- Headless smoke load:
  `nvim --headless -u NONE --cmd "set rtp+=." -c "lua require('codetime_dev').setup({ api_url = 'http://127.0.0.1:8000' })" -c "qa"`
- Behavior verification (how the plugin was originally validated): run a
  Python `http.server` mock in the scratchpad that records requests, point
  `api_url` at it with `CODETIME_TOKEN=test`, then check payloads,
  throttling, 401 pause, and queue flush after mock downtime. Avoid hitting
  the real API unless asked — it writes to the user's codetime account.

## Architecture

`lua/codetime_dev/`, all modules are singletons holding state on `M`:

- `init.lua` — `setup()`: config → autocmds → user commands → one
  `vim.uv` timer every `status_interval` that runs `tick()` =
  `client.flush()` + `status.refresh()`. `reload()` re-reads the token,
  clears the 401 pause, and ticks immediately.
- `events.lua` — autocmds → `track(buf, event_type)`. Builds the payload
  (field names/event names mirror codetime-vscode's `src/events.ts`; arch
  mapped to Node `os.arch()` names). Per-`event\0file` throttle:
  `fileEdited` uses `write_throttle`, other write events none, read events
  `read_throttle`.
- `project.lua` — project = basename of `vim.fs.root(buf, ".git")` or cwd.
  Git origin/branch cached per root; fetched **synchronously** (2s cap) the
  first time a root is seen so the first event has git info, async on
  `FocusGained` refresh.
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
