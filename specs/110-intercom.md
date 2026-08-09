# Spec 110 — Intercom (remote control from a phone)

> Status: accepted 2026-08-08, from the signed-off Design Concept of the same
> date. Companions: spec 050 (Security model), spec 020 (Architecture). Use
> canonical glossary terms only.

## Purpose

Let the operator observe and control a running DeskPilot agent from a phone,
over a messenger they already use, so a long job blocked on a question does not
idle until they are back at the machine.

Success: the operator learns a job is **blocked**, **done**, **failed**, or
**stalled** within five minutes, and can unblock it without a remote desktop
session.

## Where the feature lives

| Component | Owns | Why |
| --- | --- | --- |
| **DeskPilot** | The whole feature: transport, allow-list, per-Project policy, credential storage, audit, Settings UI | Every concept Intercom gates on — **Project**, **Permission**, **Conversation**, **Settings** — is a DeskPilot concept. The Engine has none of them. |
| **Engine (ShellPilot)** | Nothing | *The Engine is sacrosanct.* Notification, identity and policy are not Engine concerns, and DeskPilot already has the precedent of adapting the Ask-User boundary (`Read-Host` bridge, `ask_questions`) without changing the Engine. |
| **CopilotAtelier** | Check-in discipline as a Skill extension | *When* to check in, how to batch questions, how to write a phone-sized status is agent behaviour. It is decoupled from Intercom and still useful with Intercom off. |

The dividing line: **transport and policy are product code; check-in discipline
is a Skill.**

## Decisions

| Topic | Decision |
| --- | --- |
| Channel (v1) | **Telegram bot only.** A bot is six taps in BotFather, needs no admin rights, and works for the non-technical target user. Email via Microsoft Graph needs an Entra app registration that user cannot perform, so it is deferred. |
| Transport | **Long-polling `getUpdates`, outbound only.** No inbound port, no webhook, no tunnel, no public endpoint — the same rule that keeps the Host Server on `127.0.0.1`. Long-polling also *is* the adaptive cadence: a message is delivered the moment it arrives, and an idle hour costs three requests a minute with no payload. |
| Never on the accept thread | The Host Server accepts on a single thread and handles requests inline, so a 25-second long-poll on that thread would freeze the whole UI — the same failure `Invoke-DpGitCommand` exists to prevent. Every Telegram call is an **`HttpClient` `Task`** started on one tick and reaped on a later one. The pump never waits. |
| Where the pump runs | `Update-DpIntercomState` is called from **two** places: the accept loop's idle tick (so Intercom works between Turns) and `Invoke-DpPendingRequest` (so it works *during* a Turn, which is exactly when the agent asks a question). |
| Authority | A remote message may only act on a Project whose **`intercom` flag is on**. Inside such a Project a remote Turn has the *same* Permissions as a local one — including `git push` — because the flag is the boundary. With no Project selected, or the flag off, every control command is refused with a plain sentence. |
| Sender authentication | A hard **allow-list on `chat_id`**, exactly one value, configurable. An update from any other chat is counted, logged as a rejection, and dropped before its text is parsed. |
| Pairing | The allow-list creates a chicken-and-egg that would otherwise make setup impossible: Intercom will not listen until it knows the operator's chat, so the bot cannot answer *anything* - including `/start` - and there is no way to learn the id from it. **Link my phone** opens a five-minute window in which the poller runs with an empty allow-list. Every update therefore still parses as `rejected` and executes nothing; only the sender is kept as a candidate. Adoption is an explicit click at the machine, never automatic - auto-trusting the first chat to message the bot would hand control to anyone who guessed its username. Confirming a chat closes the window, discards the backlog, and restarts Intercom live. |
| Credential storage | The bot token lives in **`intercom.secret` in the data directory**, DPAPI-protected on Windows (`CurrentUser` scope) and mode-restricted elsewhere. It is never in `settings.json` (so a Settings backup cannot leak it), never returned by any route, and redacted from every log line and error message — the token is in the request URL, so an unredacted transport error would print it. |
| Correlation | Dissolved, not solved. DeskPilot runs **one Turn at a time on one Engine Runspace**, and Intercom binds to exactly **one Conversation** - the last active one, switchable with `/chats` and `/chat <n>` and rebindable with `/new`. A reply carries its nonce implicitly through Telegram's `reply_to_message`; a message with no reply is a new instruction. |
| Question nonce | Each forwarded question records the Telegram `message_id` it was sent as. An answer is accepted only when it is a **reply to that message** and the question is still pending and unexpired (`questionTimeoutMinutes`, default 60). Nothing to type at a bus stop. |
| Interrupt semantics | A message that arrives **while a Turn is running** is *queued* and delivered as the next prompt when the Turn ends. `/steer <text>` is the explicit interrupt: stop the Turn, then run `<text>`. Two honest primitives beat one ambiguous one. |
| Outbound composition | DeskPilot composes every message from **structured fields**. The one exception is the agent's question, forwarded verbatim — see *Accepted risks*. |
| Message size | Telegram caps a message at 4096 characters. `Format-DpIntercomMessage` splits on paragraph, then line, then hard boundaries, and marks each part `(n/m)`. |
| Message formatting | The agent writes Markdown and Telegram renders none of it, so a good answer arrives as a wall of `##`, `**` and pipe tables. Messages are sent as **HTML**, produced by escaping the text first and only then converting known constructs - so nothing the agent, or a file it read, wrote can inject markup. MarkdownV2 was rejected: it needs a large escape set and one miss makes Telegram reject the *whole* message, losing a result rather than formatting it badly. HTML has a tiny escape surface, and a rejected message is still retried once as plain text. Tables go into `<pre>`, the only way columns line up on a phone; italics are deliberately not converted, because underscores appear far more often in paths than as emphasis. |
| Watching a remote Turn from the window | A Turn started from the phone has no browser request to stream over, and the single-threaded accept loop rules out a long-lived SSE channel - it would hold the only thread the Host Server has. The running answer and reasoning are buffered on `Intercom.RemoteTurn` and the SPA polls `GET /api/intercom/turn`, marking the Conversation with a working badge and rendering the answer as it is written. When the Turn ends the buffer is discarded and the recorded Message replaces it, because only the Message carries the Activity, Usage and Task List. |
| Deleting a Conversation | The one irreversible thing Intercom can do, from the device where a mistyped number is most likely, so `/delete <n>` warns and only `/delete <n> confirm` acts. `/archive <n>` is offered in the same breath as the reversible alternative. |
| Rate limiting | A rolling one-hour window caps outbound messages (`maxMessagesPerHour`, default 60). Over the cap, messages are dropped and counted, not queued forever. |
| Audit | Every accepted message, every rejected message, and every outbound message is recorded in a bounded in-memory log with a UTC timestamp, exposed by `GET /api/intercom`. A rejection is a possible attack and is recorded as loudly as an acceptance. |
| Disable | One Settings toggle. Turning it off drops the in-flight poll, clears the pending question, and sends a final "Intercom off" message. |

## Failure detection (resolves F2)

The failure the operator rated fatal is *"I believe it's running, it died an hour
ago"*. The detector normally lives inside the thing that failed, so this is
solved in layers, and the residual gap is stated rather than hidden.

| Layer | Covers | Mechanism |
| --- | --- | --- |
| **1 — Stall watchdog** | A hung Engine Runspace, a deadlocked tool, an agent thinking forever | The Host Server stamps `LastActivityUtc` on every Engine Information record. While a Turn is running, if nothing has arrived for `stallMinutes` (default 5) a **single** "no activity" message is pushed — once per Turn, so it can never flood. |
| **2 — Live status message** | A dead host, a sleeping machine, a lost network, a Telegram outage | One Telegram message per enabled period, **edited in place** on every heartbeat, never re-sent. It carries an explicit `next check-in by <time>`. Telegram does not notify on an edit, so this costs zero notifications; when the machine dies the message freezes and its stated deadline goes into the past. Absence becomes a glanceable, self-dating fact instead of an ambiguous silence. |
| **3 — Farewell** | A clean shutdown: Ctrl+C, a relaunch, closing the window | The accept loop's `finally` sends one "DeskPilot stopped" message before the listener is released. |
| **4 — Stated limit** | Everything else | Sudden power loss, a hard kill, or a network drop cannot be reported by the machine itself. The getting-started guide and the Settings panel say so in plain words and tell the operator to read the status message's `next check-in by` time. |

A hosted relay or a second watchdog machine would close layer 4, and both are
declared non-goals. Claiming coverage we do not have would be worse than the
gap.

## Accepted risks

Recorded as **accepted**, not mitigated, by explicit operator decision.

- **A1 — Outbound exfiltration through the verbatim question.** The agent
  authors its own Ask-User text, so a poisoned file in a repository can make a
  well-behaved agent quote secrets into a Telegram message. Composition from
  structured fields does not close this, because the question *is* one of those
  fields. Partial mitigation falls out of the design for free: a question is only
  forwarded from a Project whose `intercom` flag is on, so a Project that is
  never remote-controlled can never exfiltrate this way.
- **A2 — No auto-disarm.** An unlocked stolen phone with Telegram open keeps
  full control until the bot token is revoked in BotFather from another device.
  There is no time-based or session-based expiry.

## Non-goals

Permanent, and named here so they are refused in review:

- **No GHCP coverage.** VS Code Copilot runs its own agent loop in a process
  DeskPilot cannot see, interrupt, or answer for. Covering it needs a different
  mechanism entirely.
- **No native mobile app.** Telegram is the client.
- **No multi-user.** Exactly one allow-listed chat.
- **No headless DeskPilot.** Intercom lives and dies with the Host Server
  process; the window must be running.
- **No hosted relay.** Nothing runs in someone else's cloud, so no external
  observer exists.
- **No webhook.** Outbound polling only.
- No remote file browsing, diff viewing, downloads, or voice.

## Commands

Every command requires the allow-listed chat. Commands that **run work** in a
Project additionally require that Project's `intercom` flag; commands that only
**navigate** DeskPilot do not, because they execute nothing. Without that split,
`/chats` would be unusable in exactly the situation where the operator needs it -
no Project open, or the wrong one.

| Message | Effect | Needs an opted-in Project |
| --- | --- | --- |
| A reply to a question message | Answers that question and releases the waiting Engine pipeline | Implicitly - the question only reaches the phone from an opted-in Project |
| Any other plain text | Runs it as a prompt on the bound Conversation - or queues it when a Turn is running | Yes |
| `/status` | Current state, Conversation, Project, elapsed time, and whether a question is pending | No |
| `/chats` | Lists the ten most recently used Conversations, newest first, marking the bound one | No |
| `/chat <n>` | Binds Intercom to that Conversation | No |
| `/archive <n>` | Archives it, rebinding if it was the bound one | No |
| `/delete <n>` | Warns; `/delete <n> confirm` removes it | No |
| `/new` | Creates a Conversation and binds Intercom to it | No |
| `/new <text>` | The same, then runs `<text>` | Yes |
| `/stop` | Cancels the running Turn | No |
| `/steer <text>` | Cancels the running Turn, then runs `<text>` | Yes |
| `/help` | The command list | No |

The numbering `/chats` produces is a **snapshot**, not a Conversation property:
the list is ordered by last activity, so running a Turn reorders it. The ids are
remembered in `Intercom.ChatIndex` and `/chat <n>` resolves against them, so the
number the operator saw is the Conversation they get.

Conversation titles are derived from prompts, so `/chats` sends that text to the
Channel. It is metadata rather than content, and it goes only to the one
allow-listed chat, but it is not covered by the `sendFinalAnswer` switch.

## Flows

### The agent asks a question while the operator is away

1. The Engine calls Ask-User. The bridge parks the Engine pipeline.
2. `Invoke-DpTurn` publishes the question to the browser as an SSE `question`
   frame **and** hands it to Intercom.
3. The pump — running from `Invoke-DpPendingRequest` inside the Turn loop —
   sends it to Telegram and records the resulting `message_id` as the nonce.
4. The operator replies to that message on their phone.
5. The next pump tick reads the update, matches the reply's
   `reply_to_message.message_id`, and calls `SubmitAnswer` on the bridge.
6. The Engine pipeline resumes. The Turn finishes. Intercom pushes the result.

### A remote prompt with no Turn running

1. The pump reads a plain message on an idle tick.
2. It checks the allow-list, the Project flag, and the rate cap.
3. It acknowledges ("Got it, working…") and runs a Turn into a discard stream —
   no browser is attached, but the Conversation, Usage, Activity and pending
   change set are updated exactly as for a local Turn.
4. `Invoke-DpPendingRequest` keeps serving the browser and the pump throughout,
   so `/stop` still works and a question can still be forwarded.
5. On completion Intercom pushes the outcome, and the final answer when
   `sendFinalAnswer` is on.

### Death

1. The heartbeat edits the status message every `heartbeatMinutes`, always
   stating the next deadline.
2. The machine dies. Nothing more is sent.
3. The operator glances at the pinned status message and reads a `next check-in
   by` time that has passed.

## Settings

Stored under `settings.intercom`; the bot token is **not** among them.

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | The single on/off switch |
| `chatId` | `null` | The one allow-listed Telegram chat |
| `heartbeatMinutes` | `5` | How often the status message is refreshed |
| `stallMinutes` | `5` | Silence inside a running Turn before the stall warning |
| `questionTimeoutMinutes` | `60` | How long a forwarded question stays answerable |
| `maxMessagesPerHour` | `60` | Rolling outbound cap |
| `notifyOnDone` | `true` | Push when a Turn finishes or fails |
| `sendFinalAnswer` | `true` | Include the answer text, split across messages |

A Project carries `intercom` (default `false`): whether it may be remotely
controlled at all.

## API

| Route | Purpose |
| --- | --- |
| `GET /api/intercom` | Status, counters, audit log, and whether a token is configured. Never the token. |
| `PUT /api/intercom` | Patch the Settings above and, write-only, set or clear `botToken`. |
| `POST /api/intercom/test` | Verify the token with `getMe` and send one test message to the allow-listed chat. |
| `POST /api/intercom/pair` | Open (or, with `{ stop: true }`, close) the five-minute pairing window. Refused with no token, and refused while a chat is already linked. |

## Implementation map

Pure, unit-testable helpers:

- `ConvertFrom-DpIntercomUpdate` — a Telegram update becomes a normalized
  command, or a rejection, with every bound applied.
- `Format-DpIntercomMessage` — structured fields become Telegram-safe text
  chunks of at most 4096 characters.
- `Test-DpIntercomProject` — is the selected Project remote-controllable?

State and transport:

- `Initialize-DpIntercom` — builds the runtime state block and the `HttpClient`.
- `Invoke-DpTelegramRequest` — the one hardened Telegram boundary: HTTPS only,
  bounded response, timeout, token redaction.
- `Send-DpIntercomMessage` — enqueues outbound work behind the rate cap.
- `Update-DpIntercomState` — the pump: reap, dispatch, drain, heartbeat, watch
  for a stall. Never throws into the accept loop.
- `Invoke-DpIntercomCommand` — executes one normalized command.
- `Read-DpIntercomSecret` / `Save-DpIntercomSecret` — the protected token at
  rest.
- `Get-DpIntercomPayload` — the API projection, with the token removed.
- `Add-DpIntercomLog` — the bounded audit ring.

## See Also

- [Getting started with Intercom](../docs/intercom-getting-started.md)
- [Spec 050 — Security model](050-security-model.md)
- [Spec 020 — Architecture](020-architecture.md)
