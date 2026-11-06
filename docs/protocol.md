# margind API (v1)

One daemon process = one workspace. All requests need
`Authorization: Bearer <token>`. JSON is snake_case.

## REST

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/v1/info` | | `{workspace, slug, color, host, machine, version, projects:[{name,path}], default_permission_mode, push, seq, boot, renders, step, tls}` (`machine`: what the app calls this computer; `boot`: changes on every daemon start, so the app knows event numbers restarted; `renders`: kicad-cli found; `step`: an OpenCascade Python found) |
| GET | `/v1/sessions` | `?project=&limit=` | `[{session_id, project, title, first_prompt, git_branch, cwd, last_modified, created_at, status, pending_permissions, proposal?}]`, most recently changed first |
| POST | `/v1/sessions` | `{project, prompt, permission_mode?}` | `{session_id}` |
| GET | `/v1/sessions/{id}/messages` | | `{session_id, items:[Item], queued:[{id, text}], status, seq}` (stored transcript) |
| POST | `/v1/sessions/{id}/messages` | `{text, permission_mode?}` | `{ok}` (resumes a stored session if needed). While Claude works the message is queued; everything queued goes as one prompt when the turn ends |
| DELETE | `/v1/sessions/{id}/queue/{queue_id}` | | `{ok}`; 404 once it was sent |
| POST | `/v1/sessions/{id}/display` | `{items:[{path, ok, detail?}]}` | `{ok}`: what the app could show of the files Claude referenced; changes reach Claude with the next prompt as a "[Margin display report]" |
| POST | `/v1/sessions/{id}/interrupt` | | `{ok}` |
| POST | `/v1/sessions/{id}/close` | | `{ok}` |
| GET | `/v1/sessions/{id}/settings` | | `{permission_mode, model, effort, models:[{value, displayName, description, supportedEffortLevels}], modes}`. The model list comes from Claude Code; empty until fetched, then a `session.settings` event follows |
| PATCH | `/v1/sessions/{id}/settings` | `{permission_mode?, model?, effort?}` (`""` = default) | Switches a live chat now (effort from its next message, by reconnecting); otherwise when it resumes. Remembered across restarts |
| GET | `/v1/permissions` | | `[PermissionRequest]` |
| POST | `/v1/permissions/{request_id}` | `{decision: "allow"\|"deny", message?, always?}` | `{ok}` |
| GET | `/v1/files` | `?project=&path=` | `[{name, path, dir, size, modified, kind}]` |
| GET | `/v1/file` | `?project=&path=` | raw bytes; `X-Modified` header is the mtime to pass back when saving |
| PUT | `/v1/file` | `?project=&path=&base_modified=&create_only=` raw body | `{ok, modified}`; 409 if the file changed since `base_modified` or exists with `create_only` |
| POST | `/v1/assist` | `{project, passage, instruction, context?, path?}` | `{text}`: Claude's revision of the passage (no tools, one turn) |
| GET | `/v1/git/refs` | `?project=` | `{branch, branches, commits}`; 422 if not a git repo |
| GET | `/v1/git/diff` | `?project=&base=&path=` | unified diff: working tree vs HEAD (with untracked files) or vs `base`; `path` limits it to one file |
| GET | `/v1/git/file` | `?project=&path=&ref=HEAD` | the file as it was at `ref` (404 if not there) |
| GET | `/v1/media` | `?path=&cwd=` | raw bytes of an image/model/PDF Claude referenced (must be inside a project) |
| GET | `/v1/resolve` | `?path=&cwd=` | `{project, path}`: a path Claude mentioned (absolute, relative to `cwd`, or relative to a folder below the project; the newest match wins), as a project file; 404 if it isn't one |
| GET | `/v1/render` | `?path=&cwd=&ref=&view=2d\|3d\|parts` | KiCad render: schematic → PDF, board → SVG (2d) or PNG (3d). `.step`/`.stp` → margin-parts JSON (`parts`, also for `2d`/default; see below). 422 with a reason if the host can't render it |
| GET | `/v1/proposals` | `?limit=` | `[Proposal]` newest first: plans Claude presented with ExitPlanMode, with their versions, your notes and the outcome |
| POST | `/v1/proposals/{id}` | `{decision: "approve"\|"revise", feedback?}` | `Proposal` |
| POST | `/v1/sessions/{id}/markup` | PNG/JPEG body | `{path}`: absolute, under `<session folder>/.margin/markup/` |
| POST | `/v1/markup` | `?project=`, PNG/JPEG body | `{path}`: the same for a markup made outside a chat (a code review), under `<project>/.margin/markup/` |
| GET | `/v1/previews/servers` | | `[{port, pid, command, cwd, project}]`: servers listening on the host, started in a folder |
| POST | `/v1/previews` | `{port}` | `{target_port, listen_port, auth_path}`: proxies `localhost:<port>` on `<bind>:<listen_port>` (from `preview_ports`); open `auth_path` there first (sets the cookie every request needs). Live-reload websockets pass through |
| DELETE | `/v1/previews/{port}` | | `{ok}` |
| POST | `/v1/devices` | `{token, name, environment}` | `{ok, push_enabled}` (APNs device token) |

Session `status`: `starting | running | waiting | idle | closed` for sessions
the daemon is driving; `stored` for transcripts on disk; `active_elsewhere`
when the transcript changed in the last 20 s and the daemon isn't driving it
(probably open in a terminal).

File `kind`: `image | svg | pdf | model | cad | kicad | markdown | csv | text | other | dir`.

### STEP parts (`margin-parts/1`)

STEP is converted on the host by a Python with OpenCascade (`cad_python` in the
workspace TOML, else found automatically) and cached until the file changes.

```json
{"format": "margin-parts/1", "units": "mm",
 "parts": [{"name": "R4", "color": [r, g, b, a],
            "positions": "<base64 float32 LE x,y,z,…>",
            "normals": "<base64 float32 LE, one per position>",
            "indices": "<base64 uint32 LE, 3 per triangle, counter-clockwise from outside>",
            "groups": [{"color": [r, g, b, a], "start": 0, "count": 1200}, …]}]}
```

One part per leaf part instance, already placed in model space (assembly
locations applied), named from the instance or product label; repeats get
" 2", " 3". Colours are sRGB 0…1 with alpha. `groups` appears only when a
part's faces carry several colours (KiCad models colour body, pins and pads
separately): contiguous ranges of `indices`, largest first, and `color` is the
first group's. Total triangles are capped near 1.5M by coarsening the mesh.

## Items

```json
{"kind": "user_text", "text": "…"}
{"kind": "text", "text": "…"}
{"kind": "thinking", "text": "…"}
{"kind": "tool_use", "id": "toolu_…", "name": "Bash", "input": {…}}
{"kind": "tool_result", "tool_use_id": "toolu_…", "is_error": false, "text": "…"}
```

All items also carry `parent_tool_use_id` (non-null inside subagents).
Long text is clipped server-side.

## Events — `GET /v1/events?since=<seq>` (WebSocket)

Every event: `{seq, type, ts, …}`. Reconnect with the last `seq` you saw
to get missed events. `resync` means refetch (`/v1/info`, sessions,
permissions, open transcripts).

| type | fields |
|---|---|
| `session.started` | `session_id, project, cwd, resumed` |
| `session.status` | `session_id, status, project` |
| `session.items` | `session_id, items:[Item]` |
| `session.queue` | `session_id, queued:[{id, text}]` (messages waiting for the turn to end) |
| `session.activity` | `session_id, activity: {started_at, tokens, doing, detail} \| null` (Claude Code's spinner line while a turn runs) |
| `session.settings` | `session_id, settings` |
| `session.replies` | `session_id, replies:[string]` (Claude's suggested replies; `[]` once you send something) |
| `session.show` | `session_id, shows:[{id, title, url?, file?, note?}]` |
| `proposal` | `proposal` (a plan presented, decided or finished) |
| `published` | `project, session_id, pages` |
| `actions` | `project, actions` |
| `ideas` | `project, ideas` |
| `session.result` | `session_id, project, is_error, subtype, num_turns, duration_ms, cost_usd, result` |
| `session.error` | `session_id, message` |
| `permission.request` | `request_id, session_id, tool_name, input, title, description, created_at, can_always_allow` |
| `permission.resolved` | `request_id, session_id` |
| `ping` | `seq` (every 25 s) |
| `resync` | `seq` |

## Push payload (APNs)

```json
{"aps": {"alert": {"title": "Main: approve Bash?", "body": "kicad-cli pcb drc …"},
         "category": "APPROVAL", "thread-id": "main:<session>"},
 "workspace": "main", "session_id": "…", "request_id": "…"}
```

Only a title and one line go through Apple. Categories: `APPROVAL` (Allow / Deny
actions), `PROPOSAL`, `RESULT`, `GENERAL`.

## On the host computer

`GET /` is a page listing sessions (status, mode, model, waiting approvals,
queued messages) and open web previews; `GET /local/status` is its JSON.
Both answer only requests from the computer itself (loopback address and a
localhost `Host` header), so they need no token; from anywhere else they 404.

## HTTPS previews

With `preview_tls` (on by default) previews are served over HTTPS, signed by
the daemon's own CA (`<state>/tls/`, made once; name-constrained to private
addresses, `localhost`, `.local` and `tls_names`). `POST /v1/previews` returns
`scheme: "https"`; `/v1/info` has `tls.ca_sha256`. `GET /v1/tls/ca.pem` and
`GET /v1/tls/margin.mobileconfig` need no token (a CA certificate is public):
the app pins the CA for its preview web view, and installing the profile on the
iPad (then Settings → General → About → Certificate Trust Settings) makes
everything trust it, WebSockets and service workers included.

## Shells

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/v1/terminals?project=` | | `[{id, project, cwd, name, screen, alive, title, offset}]`, plus `{id: null, name, detached: true}` for screen sessions left from before a daemon restart |
| POST | `/v1/terminals` | `{project?, session_id?, name?}` | A new shell in the project (or the chat's folder), or with `name` that screen session reattached |
| DELETE | `/v1/terminals/{id}` (`?name=` for a detached one) | | Ends it, screen session included |
| WS | `/v1/terminals/{id}/stream?since=<offset>` | | First a JSON `{type: start, offset, reset, name, screen}`, then output as binary frames; `{type: exit}` when the shell ends. Send input as binary frames, and `{type: resize, cols, rows}` as text |

The daemon keeps the last 512 KB of each shell's output. Offsets count every
byte the shell wrote: reconnect with the last one you have and only what you
missed comes back (`reset: false`), or everything kept (`reset: true`, clear
first). With `terminal_screen` (on by default, if GNU screen is installed)
shells run as screen sessions named `margin-<project>-<n>`, which survive
daemon restarts and can be attached at the desk with `screen -x <name>`.

## Published pages

Claude has two Margin tools (in-process MCP server `margin`, allowed without
asking): `publish_page {name, url, description?, kind?}` puts a
`http://localhost:<port>/path` page or service in the project's Preview tab
(the same name updates it); `unpublish_page {name}` removes it.
`GET /v1/published?project=` → `[{id, name, kind, port, path, description,
session_id, alive}]` (`alive`: something answers on the port);
`DELETE /v1/published?project=&id=`. Event `published {project, session_id, pages}`.

## Claude's background commands

What Claude Code already keeps, read as is: a session's Bash commands run
with `run_in_background` (from its transcript) and their output files.
`GET /v1/sessions/{id}/tasks` → `[{id, command, description, status, summary,
started_at, size}]`, newest first; `status` is Claude Code's own ending
(completed, failed, killed, stopped) or `running` (no ending yet, and either
this daemon's Claude started it or its output is still growing).
`GET /v1/sessions/{id}/tasks/{task}/output?since=` → `{start, size, text,
reset}`: from byte `since`, or the last 256 KB with `reset`. The app shows
them as read-only tabs in the chat's Shell tab.

## Buttons

Claude's `set_action {label, command | prompt | url, cwd?, description?, icon?}`
and `remove_action {label}` tools keep a project's buttons in
`<project>/.margin/actions.json` (git-excluded). `GET /v1/actions?project=` →
`[{label, kind: run|prompt|open, command?, cwd?, prompt?, url?, description,
icon, fingerprint}]`; `DELETE /v1/actions?project=&label=`;
`POST /v1/actions/run {project, label, fingerprint, session_id}` runs one and
returns `{kind: run, terminal}` (a new shell that runs the command and stays
open), `{kind: prompt}` (sent to the chat) or `{kind: open, url}`. The
`fingerprint` must match the current button (409 if it changed), so the app
shows a command before it first runs and again after any change.
Event `actions {project, actions}`.

## Ideas

Notes you keep for a project, to bring into a chat later; Claude doesn't see
them until you use one. Kept in `<project>/.margin/ideas.json` (git-excluded).
`GET /v1/ideas` → `{project: [{id, text, created_at, updated_at, used_in,
used_at}]}` for every project. `PUT /v1/ideas/{id}?project= {text, created_at?,
used_in?, used_at?}` creates or replaces one; the app picks the id, so an idea
written offline can be sent again safely when the computer is back.
`used_in` is the chat it went into (`null` puts it back on the list).
`DELETE /v1/ideas/{id}?project=` (already gone is fine). Event
`ideas {project, ideas}`.

## Showing things and suggested replies

Claude's `show {title, url | file, note?}` tool adds something to a chat's
short list of things to look at. It's in the history response as `shows` and
sent as `session.show {session_id, shows}`. The app lists them above the
message box and never takes focus; `DELETE /v1/sessions/{id}/show?id=` removes
one (without `id`, all of them).

`suggest_replies {options}` offers up to four replies you can tap; they arrive
as `session.replies` and clear when you send anything.
