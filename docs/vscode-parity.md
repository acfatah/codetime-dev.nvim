# VS Code parity

How codetime-dev.nvim maps the official
[codetime-vscode](https://github.com/codetime-dev/codetime-vscode)
extension to Neovim, where it diverges, and why.

Reference: codetime-vscode v0.14.0 (commit `d1fbb503`). Line numbers refer
to `src/codetime.ts` unless another file is named.

## Neovim concepts for VS Code users

- **Buffer**: a file loaded in memory, roughly a VS Code *document*.
- **Window**: a view onto a buffer (a split). One buffer can be shown in
  several windows.
- **Autocommand (autocmd)**: a callback Neovim runs on an event
  (`BufEnter`, `TextChanged`, ...). The equivalent of VS Code's
  `onDidXxx` listeners.
- **No workspace.** The closest things are the current directory (`cwd`)
  and the file's git root. The plugin uses the git root, falling back to
  `cwd`.
- **Special buffers** (help, terminal, file trees, quickfix) have a
  non-empty `buftype`. They are not files and are never tracked.

## Events

VS Code listeners are set up in `setupEventListeners` (L327-343); event
names live in `src/events.ts`. `operationType` is `write` for
`fileCreated`, `fileEdited`, `fileAddedLine`, `fileRemoved`, `fileSaved`,
and `read` for everything else (`getOperationType`, L396-409).

| VS Code listener | Event | VS Code rate | Neovim autocmd | Neovim rate |
|---|---|---|---|---|
| `onDidChangeActiveTextEditor` | `activateFileChanged` | every time | `BufEnter` | 1 / 120s per file |
| `onDidChangeWindowState` (focus + blur) | `editorChanged` | every time | `FocusGained`, `FocusLost` | 1 / 120s per file |
| `onDidChangeTextDocument` | `fileEdited` | ~10% random | `TextChanged`, `TextChangedI` | 1 / 10s per file |
| same, change inserts a newline | `fileAddedLine` | every time | same, line count grew | 1 / 10s per file |
| `onDidChangeTextEditorSelection` | `changeEditorSelection` | ~10% random | `CursorMoved` | 1 / 30s per file |
| `onDidChangeTextEditorVisibleRanges` | `changeEditorVisibleRanges` | 300ms debounce | `WinScrolled` | 1 / 30s per file |
| `onDidSaveTextDocument` | `fileSaved` | every time | `BufWritePost` | every time |
| `onDidCreateFiles` | `fileCreated` | every time | first `BufWritePost` after `BufNewFile` | every time |
| (none, constant only) | `fileRemoved` | never sent | (none) | never sent |

The rates are configurable: `read_throttle`, `write_throttle`,
`cursor_throttle`.

## Payload

`POST /v3/users/event-log`, JSON body built in `onChange` (L411-465).
Exactly these 12 fields; the token is not in the body.

| Field | VS Code | Neovim |
|---|---|---|
| `project` | workspace name (`vscode.workspace.name`) | git root name, else `cwd` name |
| `language` | `document.languageId` | `filetype`, else `"plaintext"` |
| `relativeFile` | `asRelativePath`, `"[other workspace]"` when outside | same, relative to project root |
| `absoluteFile` | `document.fileName` | buffer name |
| `editor` | `vscode.env.appName` | `"Neovim"` (option `editor`) |
| `platform` | npm `os-name`, e.g. `"Linux 6.18"` | `uname` sysname + release |
| `eventTime` | `Date.now()` (ms) | `gettimeofday` (ms) |
| `eventType` | event name | same |
| `platformArch` | Node `os.arch()` (`x64`, `arm64`) | `uname` machine mapped to Node names |
| `gitOrigin` | `git remote get-url origin`, `""` on failure | same |
| `gitBranch` | `git rev-parse --abbrev-ref HEAD`, `""` on failure | same (`"HEAD"` when detached) |
| `operationType` | `read` / `write` | same |

Git info: VS Code runs git in the first workspace folder and returns `""`
on any failure (`src/utils.ts` L34-86). The plugin runs it in the file's
project root and caches it per root, refreshing on `FocusGained` (the
branch may change outside the editor). In a repo with no commits yet,
`rev-parse` fails, so `gitBranch` is `""` in both clients.

Headers (`apiRequest`, L69-267): `Authorization: Bearer <token>`,
`User-Agent: CodeTime Client`, `Content-Type: application/json`. Timeout
30s.

## Deliberate divergences

| Topic | VS Code | Neovim | Why |
|---|---|---|---|
| Rate limiting | random ~10% sampling of edits and selections | per-file, per-event throttle | deterministic and testable; `CursorMoved` fires far more often than VS Code's selection event |
| Read events | not throttled | 120s per file | `BufEnter` also fires when moving between splits |
| Failed sends | dropped (only logged, L458) | queued in memory, retried every `status_interval` | fewer lost events on flaky networks |
| 401 | status text "Auth Failed", keeps sending | warn once, pause until `:CodeTimeDevReload` | no request storm with a bad token |
| Filtering | only the `output` scheme skipped | all non-file buffers skipped | Neovim has many non-file buffers |
| Status text | date-fns, e.g. `"1 hour 23 minutes"` | `"1h 23m"` | fits a statusline |
| Status period | setting `Total` / `24h` / `Today` (default Total) | today only | the dashboard "today" number |
| Token | VS Code SecretStorage, env, prompt | `opts.token`, `$CODETIME_TOKEN`, `~/.codetime/config.json` | shared with codetime-cli and Zed |

The minutes endpoint is the same:
`GET /v3/users/self/minutes?minutes=<minutes since local midnight>` →
`{ "minutes": n }`, refreshed every 60s.

## Porting approach

Three options were considered:

- **A. Literal port** (random sampling, no throttle, drop failures):
  faithful, but untestable and far more requests, because cursor motion
  in Neovim fires constantly.
- **B. Same contract, Neovim-suited rate limits** (chosen): the same event
  types and payload shape as VS Code, so the server sees the same kinds
  of data, with deterministic throttling.
- **C. Keep the original behavior**: reading and navigating one file sent
  nothing, so reading time could be under-reported.

How the server turns events into minutes is not public. Fewer events can
only mean the same or fewer minutes, so the plugin sends every event type
VS Code sends.

## Gotchas

- `FocusGained` / `FocusLost` only fire if the terminal reports focus
  changes. In tmux, set `set -g focus-events on`.
- `TextChangedI` fires on almost every keystroke and `CursorMoved` on
  every motion. The throttle is checked before any file-system or git
  work, so these stay cheap.
- `BufEnter` fires when switching between splits of the same file; the
  per-file throttle absorbs it.
- `BufNewFile` fires when you open a path that does not exist yet, not
  when the file is created. `fileCreated` is sent on the first write
  instead, when the file actually exists.
