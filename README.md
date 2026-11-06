<p align="center"><img src="docs/images/icon.png" width="96" alt="Margin app icon"></p>

# Margin

An iPad remote for Claude Code, built around the Apple Pencil.

Claude Code keeps working on your own computers; Margin brings you what needs
you. Read what Claude did, draw on it, and send it back: a chat message, a
plan, a diff, a render, a web page it's running. Every stroke goes back with
what it landed on, in words ("circled `one to many (custom)`", "on the added
line `if p.Index < 0`"), so Claude can act on it.

![A chat on the iPad](docs/images/chat.jpg)

- **Chats are normal Claude Code sessions.** Anything started from the iPad
  shows up in `claude --resume` at the desk and the other way round, with the
  same CLAUDE.md, memory, settings, MCP servers and skills.
- **Plans become documents.** When Claude presents a plan (`ExitPlanMode`), Margin
  shows it as a document with a card per section: comment on or draw on any
  section, pick between the options Claude offers, leave sections out, then
  approve it or send it back. The next version leads with what changed.
- **Mark up anything.** With the Pencil, touch a message, plan, diff, PDF,
  image, 3D model, KiCad render or web preview and you're drawing on it; no
  screenshot step.
- **Changes, Files, Preview, Shell.** Each chat has its git changes (uncommitted
  or since any commit) to review line by line, the project's files with
  previews, the dev servers Claude started (proxied to the iPad, live reload
  included), and real shells on the host.
- **Additive, never in your way.** Claude can point you at something, offer
  replies to tap or add a button for a command you run often; none of it takes
  focus.
- **Ideas, and reading offline.** Jot ideas down per project, even with the
  computer out of reach, and bring them into a chat when the time is right;
  nothing goes to Claude until you send it. The chats you opened last stay
  readable offline.
- **Voice.** Dictate messages and replies, with iPadOS 26's on-device speech
  analyzer where available.
- **iPad first, iPhone too.** The same app works on iPhone and on Apple Silicon Macs.

| | |
|---|---|
| ![Claude waiting on you: a command to allow, in the chat and the sidebar](docs/images/approval.jpg) | ![Replies Claude suggests, above the message box](docs/images/suggestions.jpg) |
| ![The dev server Claude started, through the preview proxy](docs/images/preview.jpg) | ![A real shell on the host](docs/images/shell.jpg) |
| ![Claude's background command and its live output](docs/images/process.jpg) | ![A plan as a document, with your notes on the last version](docs/images/plan.jpg) |
| ![Changes since a commit, ready to comment on](docs/images/changes.jpg) | ![A board render marked up with the Pencil](docs/images/markup.jpg) |
| ![A project's ideas, waiting to be brought into a chat](docs/images/ideas.jpg) | ![A chat read offline; what you write is kept as an idea](docs/images/offline.jpg) |
| ![Source with tree-sitter colouring](docs/images/code.jpg) | <img src="docs/images/iphone.jpg" width="300" alt="The same chat on iPhone"> |

## Architecture

![Architecture: the Margin app, margind on each computer, and Claude Code](docs/images/architecture.svg)

- **`margind`** is a small Python daemon that runs on each computer you want
  to reach, with its own projects and token. It runs Claude Code through the
  Claude Agent SDK, as you, in your project folders, and serves the app over
  HTTP and a WebSocket. It stays thin: it drives the real Claude Code, reads
  what Claude Code already writes, and adds only what a tablet needs.
- **Margin** is a SwiftUI app. It talks to every computer you've added and
  shows their projects and chats side by side in one sidebar, merged on the
  device only; the computers never talk to each other.

Hosts: macOS, Linux and Windows, with Python 3.11+ and
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and
logged in (`claude` works in a terminal). macOS is used every day; Windows
support is new (shells through ConPTY, tested in CI) and on Windows app shells
end when the daemon stops.

### A chat, end to end

1. You type or speak in a chat. The app posts it; the daemon hands it to that
   chat's Claude Code process, starting one with `resume` if the chat was idle.
   The app shows *Sending*, then *Starting Claude Code*, then *Thinking*.
2. Claude works as it would at the desk. The daemon reads its output
   continuously and turns each message into an event on the WebSocket. Every
   event has a sequence number, so after a dropped connection or a daemon
   restart the app catches up on what it missed.
3. When Claude needs permission, the SDK's callback holds the tool call and the
   app gets an approval (and a push, if set up). Plans (`ExitPlanMode`) arrive
   in the folio to mark up, then approve or send back.
4. Pencil marks are saved as PNGs in the project's `.margin/markup/`, with a
   sentence for each stroke saying what it landed on, and go with your reply
   for Claude to read.

### Claude Code's, used as is

- **The agent:** the real Claude Code with your settings, CLAUDE.md, skills and
  MCP servers.
- **Chats:** its transcripts are the source of truth, so the desk and the app
  see the same chats.
- **Background commands** (dev servers, watchers): read from its transcript
  and output files and shown in the Shell tab. They end with the Claude
  process, as at the desk.
- **Modes, models and effort:** its own, set per chat.

### What Margin adds

- **Reaching the computer:** token auth, event replay, pairing links and QR codes.
- **Seeing work:** a preview proxy with HTTPS and in-page ink, file renders
  (PDF, images, KiCad, STEP), git review since any commit.
- **Hands on the computer:** real shells, kept alive in GNU screen where it exists.
- **Tools for Claude** (an in-process MCP server): `show` points you at a file,
  line or diff; `suggest_replies` offers replies to tap; `publish_page` adds a
  page to the Preview tab; `set_action` adds a button for a command. None of
  them take focus.
- **Hooks** that keep Claude from opening windows on the host and remind it
  you're reading on a tablet.

### Where state lives

| | |
|---|---|
| Claude Code's own files | chats and background command output; Margin never writes them |
| `~/.margin/` | device tokens; per workspace: its TLS CA, per-chat settings, plan versions with decisions, published pages, registered devices |
| `.margin/` in a project | markup images, buttons, ideas |
| On the device | paired computers (tokens in the Keychain), sidebar order, view settings; per computer, a copy of the chat list, the chats opened last, plans and ideas for reading offline (unreadable while locked, not backed up) |

### Code map

| | |
|---|---|
| `daemon/margind/server.py` | FastAPI app: HTTP routes, the events and terminal WebSockets, auth |
| `sessions.py` | live Claude Code sessions: the reader, approvals, hooks, Margin's tools, history |
| `normalize.py` | SDK messages and transcript lines into the one JSON shape the app renders |
| `events.py` | the event bus: sequence numbers, replay buffer, boot id |
| `proposals.py`, `scope.py` | plans and their versions; which commands an approved plan may run without asking |
| `bgtasks.py` | Claude Code's background commands |
| `terminals.py` | shells: pty + GNU screen on macOS/Linux, ConPTY on Windows |
| `preview.py`, `tls.py` | dev servers, the HTTPS proxy per port, the daemon's own CA |
| `files.py`, `gitreview.py`, `render.py`, `step.py` | project files, git diffs, KiCad renders, STEP to 3D |
| `push.py`, `writing.py`, `localpage.py`, `desk.py` | APNs, "revise this passage", the local page and its Open in… buttons |
| `ideas.py`, `actions.py` | a project's ideas and Claude's buttons, in `.margin/` |
| `ios/Margin/Model/` | `AppModel` (all computers), `WorkspaceState` (one computer's live state), `Offline` (the device copy and ideas waiting to sync) |
| `ios/Margin/Networking/` | `HostAPI`: the HTTP and WebSocket client for one daemon |
| `ios/Margin/Views/` | sidebar, chat, plans, Pencil, code, shell, web preview, `Theme` |

The daemon's HTTP and WebSocket API is in [docs/protocol.md](docs/protocol.md).

## 1. Run the daemon

macOS / Linux:

```bash
git clone <this repo> margin && cd margin/daemon
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[push,qr]"

mkdir -p ~/.margin
margind token >> ~/.margin/main.tokens      # one line per device
cp workspaces/main.example.toml workspaces/main.toml
# edit main.toml: your projects, bind address, colour

margind serve -c workspaces/main.toml       # port 8787
```

Windows (PowerShell):

```powershell
git clone <this repo> margin; cd margin\daemon
py -3 -m venv .venv; .venv\Scripts\Activate.ps1
pip install -e ".[push,qr]"

mkdir $HOME\.margin -Force
margind token | Out-File -Append -Encoding ascii $HOME\.margin\main.tokens
copy workspaces\main.example.toml workspaces\main.toml
# edit main.toml (paths like C:/src/my-app work)

margind serve -c workspaces\main.toml
```

`workspaces/*.toml` (except the examples) and `*.tokens` are git-ignored.
Every request needs a token, except the daemon's public CA certificate (for
HTTPS previews) and a page that only answers the computer itself, at
`http://127.0.0.1:8787/`: what's running, and each project with **Open in…**
(the editors installed there) and **Folder**.

To keep it running: `deploy/macos/com.margin.main.plist` (launchd),
`deploy/linux/margind@.service` (systemd user unit) or
`deploy/windows/install-workspace.ps1`. Edit the paths in them first.

### Reaching it from the iPad

The app connects over plain HTTP to private addresses: your LAN, or a VPN such
as ZeroTier or Tailscale for when you're out. Set `bind = "0.0.0.0"` (or the
VPN address) in the workspace TOML, then print a pairing link:

```bash
margind pair -c workspaces/main.toml --url http://192.168.1.20:8787
```

It prints a `margin://add?…` link and, with the `qr` extra, a QR code. Scan it
with the iPad camera, or paste the link in **Add workspace**.

Want HTTPS on a name instead? `deploy/Caddyfile` puts Caddy in front, bound to
the VPN address only, with a Let's Encrypt certificate from a DNS challenge.
Web previews are served over HTTPS either way, signed by the daemon's own
certificate authority (see [docs/protocol.md](docs/protocol.md#https-previews)).

## 2. Build the app

Needs a Mac with Xcode 26 (the app runs on iOS/iPadOS 17 and later; voice
uses iPadOS 26's speech analyzer when it's there) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd margin/ios
cp Signing.xcconfig.example Signing.xcconfig   # your Team ID and a bundle id of your own
xcodegen && open Margin.xcodeproj
```

Run it on your iPad from Xcode, or Archive → TestFlight (internal testing
needs no review). It needs a paid Apple Developer account: the app carries the
push notifications entitlement, which a free Apple ID can't sign.

## 3. Push notifications (optional)

Approve tool calls and plans from the lock screen.

1. developer.apple.com → Keys → a new key with **Apple Push Notifications service**; download the `.p8`.
2. Put it in `~/.margin/` on each host and fill in `[apns]` in the workspace
   TOML (`bundle_id` = your `MARGIN_BUNDLE_ID`; `sandbox = true` for Xcode
   builds, `false` for TestFlight).
3. Restart the daemon and reopen the app; it registers itself with every workspace.

Notifications carry only a title and one line ("approve Bash?
npm test …"). The content itself loads from your host when you open
the app.

## 4. More computers

Set up the daemon the same way on every computer you want to reach (a desktop,
a laptop, a Linux box on the bench), pair each one, and they all show up in
the same app. The sidebar groups chats by computer, labelled with its own name
(set `machine` in the TOML to change it), and a chat or approval from any of
them can reach you.

One computer can also run several workspaces, each with its own port, token,
projects and Claude Code login, for when you keep separate accounts (see
`workspaces/second-login.example.toml`):

```toml
claude_config_dir = "~/.claude-second"     # its own login, history, settings
# api_key_env = "SECOND_ANTHROPIC_API_KEY"  # or bill it to its own API key
```

Log that folder in once at the desk (`CLAUDE_CONFIG_DIR=~/.claude-second
claude`, then `/login`). The sidebar adds the workspace name when one computer
runs several.

Check Anthropic's current terms for how subscription logins may be used
through the Agent SDK; an API key sidesteps the question.

## Optional host tools

- **KiCad** (`kicad-cli` on the PATH or in its usual install folder): schematics
  and boards render in the app, and you can draw on them.
- **STEP models**: set `cad_python` to a Python with `cadquery-ocp`, or keep one
  in `~/.venvs/*`, and assemblies show as 3D models you can explode.
- **GNU screen** (macOS/Linux): app shells outlive daemon restarts and can be
  attached at the desk with `screen -x margin-<project>-<n>`.

## Development

```bash
cd daemon && pip install -e ".[dev]" && pytest -q    # a fake SDK client: no Claude login needed
```

The tests run on macOS, Linux and Windows in CI (`.github/workflows/daemon.yml`).

Debug builds of the app take a few launch settings, handy with the Simulator
(`SIMCTL_CHILD_<name>=… xcrun simctl launch …`): `MARGIN_ADD` (a pairing link),
`MARGIN_OPEN` (`<workspace>/session/<id>`, `<workspace>/proposal/<id>` or `<workspace>/ideas/<project>`),
`MARGIN_TAB`, `MARGIN_FILE`, `MARGIN_DIFF_BASE`, `MARGIN_EDIT`, `MARGIN_PREVIEW` (a port),
`MARGIN_SHELL` (a shell id, or `task:<id>`) and `MARGIN_NO_PUSH` (skip the notification prompt).

- [docs/protocol.md](docs/protocol.md): the daemon's HTTP and WebSocket API.
- `ios/Margin/Views/Theme.swift`: colours, type and spacing in one place.
- `design/icon/`: the app icon's sources.
