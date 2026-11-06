# Working on Margin with Claude Code

Margin is easy to change while you use it. Keep a Claude Code session open in
this repo, let it run the daemon in the background, and ask for changes:
it edits the code, runs the tests, restarts the daemon or installs a new build
on your iPad, and the app picks the change up. This is how Margin itself was
built.

## The loop

1. **Run the daemon from Claude Code.** In a Claude Code session in this repo,
   ask it to start the daemon in the background:

   ```bash
   cd daemon && uv run margind serve -c workspaces/main.toml
   ```

2. **Daemon changes:** edit, `uv run pytest -q`, then restart the daemon. The
   app reconnects by itself: it sees the daemon's new boot id and reloads what's
   open. Chats aren't lost (they're Claude Code's own transcripts), but a
   restart ends whatever is live, so check first (below).

3. **App changes:** build and install on a device connected by cable or on the
   same network:

   ```bash
   cd ios && xcodegen
   xcodebuild -project Margin.xcodeproj -scheme Margin -destination 'generic/platform=iOS' \
     -derivedDataPath build -allowProvisioningUpdates build
   xcrun devicectl list devices                     # find the device's identifier
   xcrun devicectl device install app --device <id> build/Build/Products/Debug-iphoneos/Margin.app
   ```

   Pairings survive reinstalls (tokens are in the Keychain). If `xcodebuild`
   says it needs Xcode rather than the command line tools, prefix it with
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

4. **Look before you ship:** the Simulator with the debug launch settings
   (`MARGIN_OPEN`, `MARGIN_TAB`, … in the README) opens any screen directly,
   and `xcrun simctl io <device> screenshot` captures it.

## Before restarting the daemon

A restart cuts off anything in flight: a turn Claude is working on, an approval
or a plan waiting for you, and the background commands Claude started (dev
servers end with their Claude process). The local page shows all of it, and
needs no token from the computer itself:

```bash
curl -s http://127.0.0.1:8787/local/status
```

Restart when nothing is `running` or `waiting` and no `tasks` are listed, or
say what will be cut off and ask first.

**Don't restart the daemon your own chat runs through.** If you're talking to
Claude *from Margin* about Margin, restarting that daemon ends the very chat
you're in. Either drive the work from Claude Code at the desk, or run a second
workspace for development (next section) and restart only that one.

## A second workspace for testing

A workspace is just a TOML file: copy `workspaces/main.example.toml`, give it
its own `name`, `port` (say 8799), `token_file` and `state_dir`, and a project
or two made for the purpose. Pair the Simulator (or a second device) with it.
Screenshots and experiments then never show your real projects, and restarting
it touches nothing you're working on. Tokens and real workspace files are
git-ignored; keep it that way.

## Tests

- Daemon: `cd daemon && uv run pytest -q`. A fake SDK client stands in for
  Claude Code, so no login is needed. CI runs the same on macOS, Linux and
  Windows.
- App: build for the Simulator (`-destination 'generic/platform=iOS Simulator'
  -derivedDataPath build-sim`) to catch compile errors without a device.

When the API changes, update [protocol.md](protocol.md); when how things fit
together changes, [architecture.md](architecture.md).
