# Margin

An iPad/iPhone remote for Claude Code: `daemon/` is `margind` (Python,
FastAPI, the Claude Agent SDK), `ios/` is the SwiftUI app (XcodeGen).
How it fits together: docs/architecture.md. The API: docs/protocol.md.
How to work on it while using it: docs/development.md.

## Commands

- Daemon tests: `cd daemon && uv run pytest -q` (a fake SDK client, no login).
- Run a workspace: `cd daemon && uv run margind serve -c workspaces/<name>.toml`,
  in the background.
- App: `cd ios && xcodegen`, then `xcodebuild` for the Simulator to check it
  compiles, or for a device and `xcrun devicectl device install app` (see
  docs/development.md). Prefix with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if xcode-select
  points at the command line tools.

## Rules

- **Before restarting a daemon**, check `curl -s http://127.0.0.1:<port>/local/status`.
  If a chat is `running` or `waiting`, or Claude has background `tasks`
  running, say what a restart would cut off and ask. Never restart the daemon
  the user's current chat runs through without saying so.
- **Never print tokens or pairing links/QR codes.** Tokens live in
  `~/.margin/*.tokens`; read them inside a command (`T=$(head -1 …)`), never
  echo them. Workspace TOMLs other than the examples are git-ignored.
- **Margin is additive:** nothing Claude does through it takes focus on the
  host or the iPad. Follow Claude Code's own behaviour where there's a choice.
- When an endpoint or event changes, update docs/protocol.md in the same change.
- Daemon changes get a test; app changes get a Simulator build at least.
