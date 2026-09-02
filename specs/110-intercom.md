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
| Sender authentication | A hard **allow-list on `chat_id`**. The operator's own chat is always the primary one; **shared group chats** can be added alongside it, and are refused unless *both* `allowGroupChat` is on and `groupChatIds` holds at least one id. Up to ten, so the allow-list stays bounded. An update from any other chat is counted, logged as a rejection, and dropped before its text is parsed. Two gates rather than one list, because allow-listing a group is not the same kind of act as allow-listing a phone - see *Accepted risks*. |
| Where a reply goes | **Answer where you were asked.** Every queued message carries the chat the interaction it belongs to came from, so work requested in the group is acknowledged, questioned and reported in the group rather than surfacing privately. A Turn started from the window, and every message DeskPilot sends on its own initiative, goes to the operator's chat. The live status message is the deliberate exception: there is exactly one of it, edited in place against a single `message_id`, and it belongs to the operator. |
| Answering across two chats | Telegram message ids are **per-chat sequences**, so with two chats allow-listed an unrelated reply in one can carry the same id as the question pending in the other. The pending question therefore records the chat it was sent to, and a reply is only an answer when it replies to that message *in that chat*; anywhere else it is an ordinary prompt. |
| Addressing a group message | Under Telegram's group privacy a plain instruction only reaches the bot if it **@mentions** it, so that mention is *addressing, not content* - the same reason `/command@BotName` already loses its suffix. A leading mention of the bot's own name is stripped before the text becomes a prompt, on a word boundary so `@bot2` is not read as `@bot`. Left in, it reached the agent as the first words of the work and became the Conversation title, which is derived from them. The name comes from one non-blocking `getMe` started on the enable transition; if it fails, nothing is stripped and the only cost is the noise. |
| Pairing | The allow-list creates a chicken-and-egg that would otherwise make setup impossible: Intercom will not listen until it knows the operator's chat, so the bot cannot answer *anything* - including `/start` - and there is no way to learn the id from it. **Link my phone** opens a five-minute window in which the poller runs with an empty allow-list. Every update therefore still parses as `rejected` and executes nothing; only the sender is kept as a candidate. Adoption is an explicit click at the machine, never automatic - auto-trusting the first chat to message the bot would hand control to anyone who guessed its username. Confirming a chat closes the window, discards the backlog, and restarts Intercom live. |
| Credential storage | The bot token lives in **`intercom.secret` in the data directory**, DPAPI-protected on Windows (`CurrentUser` scope) and mode-restricted elsewhere. It is never in `settings.json` (so a Settings backup cannot leak it), never returned by any route, and redacted from every log line and error message — the token is in the request URL, so an unredacted transport error would print it. |
| Archived and deleted Conversations | A remote Turn is refused when the bound Conversation is archived or gone, through the same `Test-DpConversationWritable` the window's own routes use. Intercom used to fall back to "the most recent Conversation" when its binding had gone, which meant the work quietly happened somewhere the operator never chose. |
| Selecting an Agent, a Model or a Project | All three are navigation, not work: they change which system prompt, which Model and which folder the *next* Turn uses and execute nothing, so none of them needs an opted-in Project - the same split that keeps `/chats` usable when no Project is open. Because a Project switch can change whether the next instruction is allowed to run at all, the reply always states the remote-control status of the Project it moved to. A Model switch writes both the Settings default **and** the bound Conversation's pin, because `Invoke-DpTurn` prefers the pin - writing only Settings would be a silent no-op for exactly the Conversation the operator is talking to. |
| Creating a Project remotely | `/project new <path>` writes to disk, so it requires the currently selected Project to have opted in - a phone that cannot run anything cannot create folders either. Only the **last** segment of the path is created, so a typo cannot build a tree. The new Project is **never** remote-enabled: if a remote message could opt a folder into remote control, the Project flag would be decorative, because anyone holding the phone could point DeskPilot at any folder and run there. The flag is set at the machine, and the reply says so. A path that is already registered switches to that Project instead of failing on a duplicate the operator cannot see from a phone. |
| Correlation | Dissolved, not solved. DeskPilot runs **one Turn at a time on one Engine Runspace**, and Intercom binds to exactly **one Conversation** - the last active one, switchable with `/chats` and `/chat <n>` and rebindable with `/new`. A reply carries its nonce implicitly through Telegram's `reply_to_message`; a message with no reply is a new instruction. |
| Edited messages | Fetched (`allowed_updates` includes `edited_message`) and **acknowledged, never executed**. Editing a typed command is natural on a phone, and silently discarding it produced a correction that vanished with no reply. Acting on one would be worse: Telegram delivers an edit as a fresh update, so a command that already ran could run again with different text, potentially hours later. The allow-list applies first, so an edit from another chat is still a silent rejection. |
| Question nonce | Each forwarded question records the Telegram `message_id` it was sent as. An answer is accepted only when it is a **reply to that message** and the question is still pending and unexpired (`questionTimeoutMinutes`, default 60). Nothing to type at a bus stop. |
| Interrupt semantics | A message that arrives **while a Turn is running** is *queued* and delivered as the next prompt when the Turn ends. `/steer <text>` is the explicit interrupt: stop the Turn, then run `<text>`. Two honest primitives beat one ambiguous one. |
| Outbound composition | DeskPilot composes every message from **structured fields**. The one exception is the agent's question, forwarded verbatim — see *Accepted risks*. |
| Message size | Telegram caps a message at 4096 characters. `Format-DpIntercomMessage` splits on paragraph, then line, then hard boundaries, and marks each part `(n/m)`. |
| Tables | Telegram has **no table support** - the Bot API offers bold, italic, underline, strike, spoiler, code, `pre`, blockquote and links, and nothing else - so a table can only be approximated, and the approximation must depend on its width. A narrow table becomes a `<pre>` block with padded columns. A wide one becomes **one labelled record per row**, because once Telegram wraps a monospaced line the alignment that block existed for is gone and it reads worse than no table at all. Either way the rows are capped (15) with a count of what was left out: a 141-row table is several screens of noise on a phone, and the machine is where the full thing is read. |
| Attachments | A Telegram file message carries **no `text`** - the words are in `caption` and the file sits in a differently shaped member per kind - so reading only `text` made an attachment vanish with no reply. Documents, photos, audio, video and voice notes are now fetched across the two calls Telegram requires (`getFile`, then the content), both started on one pump tick and reaped on a later one, and written into the same folder and Attachment registry browser uploads use. The prompt names the saved path; an image is also handed to the Engine's native Vision input. Guarded by size (`maxAttachmentMB`, default 20, Telegram's own ceiling), by sanitising the sender-supplied file name to a leaf, and by validating the path `getFile` returns so it can only address the bot's own file root. **Vision has its own, much smaller budget** (`Get-DpVisionBudgetError`), because an image is inlined into the Turn as base64 and an oversized one fails the whole request at the Copilot endpoint; there is no browser here to downscale it first, so such an image is saved and named but refused as a Vision input, with the reason sent back to the operator. The file's *content* is untrusted and the agent will read it - the same accepted risk as any file in a Project. |
| Message formatting | The agent writes Markdown and Telegram renders none of it, so a good answer arrives as a wall of `##`, `**` and pipe tables. Messages are sent as **HTML**, produced by escaping the text first and only then converting known constructs - so nothing the agent, or a file it read, wrote can inject markup. MarkdownV2 was rejected: it needs a large escape set and one miss makes Telegram reject the *whole* message, losing a result rather than formatting it badly. HTML has a tiny escape surface, and a rejected message is still retried once as plain text. Italics are deliberately not converted, because underscores appear far more often in paths than as emphasis. |
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
| **1 — Stall watchdog** | A hung Engine Runspace, a deadlocked tool, an agent thinking forever | The Host Server stamps `LastActivityUtc` on every Engine Information record. While a Turn is running, if nothing has arrived for `stallMinutes` (default 5) a **single** "no activity" message is pushed — once per Turn, so it can never flood. **A Turn parked on a forwarded question is not a stall**: DeskPilot knows exactly why nothing is happening, so it sends a reminder that names the wait instead of saying the agent "may be stuck" and offering `/stop` — which invited the operator to kill a job that was only waiting for them. Submitting the answer counts as activity and re-arms the watchdog, so a genuine stall afterwards is still reported. |
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
- **A3 — A group shares the operator's authority.** With `allowGroupChat` on,
  every member of every allow-listed group holds exactly the control the operator
  does: instructions, answers to the agent's questions, and work in an opted-in
  Project including `git push`. Membership is Telegram's to change, so anyone an
  admin adds later inherits it, and DeskPilot never learns that it happened.
  There is no per-sender allow-list inside a group and no per-member
  Permission - Intercom carries one authority, not accounts. Mitigation is
  confined to making the consequence unmissable: the feature is off by default,
  needs two separate switches, is capped at ten groups, states the consequence
  where it is enabled, and repeats it on every `/status` check-in.

## Non-goals

Permanent, and named here so they are refused in review:

- **No GHCP coverage.** VS Code Copilot runs its own agent loop in a process
  DeskPilot cannot see, interrupt, or answer for. Covering it needs a different
  mechanism entirely.
- **No native mobile app.** Telegram is the client.
- **No per-sender identity.** Intercom carries exactly one authority - the
  operator's. A shared group chat may be allow-listed alongside the operator's
  own, but that widens *who can exercise that one authority*; it does not create
  users, roles or per-member Permissions, and DeskPilot never distinguishes one
  group member from another.
- **No headless DeskPilot.** Intercom lives and dies with the Host Server
  process; the window must be running.
- **No hosted relay.** Nothing runs in someone else's cloud, so no external
  observer exists.
- **No webhook.** Outbound polling only.
- No remote file browsing, diff viewing, downloads, or voice.

## Commands

Every command requires an allow-listed chat. Commands that **run work** in a
Project additionally require that Project's `intercom` flag; commands that only
**navigate** DeskPilot do not, because they execute nothing. Without that split,
`/chats` would be unusable in exactly the situation where the operator needs it -
no Project open, or the wrong one.

Telegram hides ordinary group messages from bots unless **Group Privacy** is
turned off in BotFather, so in a group a bot with privacy on only ever sees
`/commands`, replies to itself, and messages that @mention it. That is a
Telegram-side setting DeskPilot cannot read or change, so it is stated in the
Settings panel and the getting-started guide rather than detected.

| Message | Effect | Needs an opted-in Project |
| --- | --- | --- |
| A reply to a question message | Answers that question and releases the waiting Engine pipeline | Implicitly - the question only reaches the phone from an opted-in Project |
| A tap on an inline-keyboard button | Answers a question, or switches Conversation, Agent, Model or Project from the matching listing | As above |
| Any other plain text | Runs it as a prompt on the bound Conversation - or queues it when a Turn is running | Yes |
| `/status` | Current state, Conversation, Project, Agent, Model, elapsed time, and whether a question is pending | No |
| `/chats` | Lists the ten most recently used Conversations, newest first, marking the bound one. `/chats all` includes archived ones, marked - they are the ones already finished with, so they stay out of the way until their numbers are needed | No |
| `/chat <n>` | Binds Intercom to that Conversation | No |
| `/agents` | Lists the Agents under the effective Agents folder, marking the selected one | No |
| `/agent <n>` | Selects that Agent for the next Turn. `/agent none` clears the selection and returns to the Engine's own prompt | No |
| `/models` | Lists the Models this account is offered, marking the one the next Turn would run on | No |
| `/model <n>` | Selects that Model for the next Turn. `/model default` clears the choice and returns to DeskPilot's own default | No |
| `/projects` | Lists the registered Projects, marking the open one and stating on every line whether it allows remote control | No |
| `/project <n>` | Selects that Project | No |
| `/project new <path>` | Registers a folder as a Project and selects it, creating the folder when only its last segment is missing | Yes |
| `/archive <n>` | Archives it, rebinding if it was the bound one | No |
| `/unarchive <n>` | Brings an archived one back | No |
| `/delete <n>` | Warns; `/delete <n> confirm` removes it | No |
| `/new` | Creates a Conversation and binds Intercom to it | No |
| `/new <text>` | The same, then runs `<text>` | Yes |
| `/stop` | Cancels the running Turn | No |
| `/steer <text>` | Cancels the running Turn, then runs `<text>` | Yes |
| `/undo` | Warns; `/undo confirm` restores the bound Conversation's most recent **Checkpoint** (see [030-api-contract.md](030-api-contract.md)) - dropping that prompt and everything after it, and putting back the files those Turns wrote. Refused while a Turn is running or on an archived Conversation. The discarded prompt is sent back so it can be reworded and resent | No |
| `/help` | The command list | No |

`/undo` is the only Intercom command that rewrites files on disk, and a phone is
where a mistyped command is most likely, so it takes two messages - the same
two-step shape as `/delete`. The confirmation states the exact number of Messages
and files at stake, taken from a real `Restore-DpCheckpoint -Preview` rather than
an estimate, so the operator is never asked to confirm a guess.

### Selecting a Model

`/models` reads the capability list the `/api/models` route caches on
`$script:DeskPilot.Models`. A DeskPilot driven only from the phone may never have
had a browser call that route, so an empty cache is refilled from the Engine -
but **only while no Turn is running**. The Engine Runspace is single-threaded, so
asking it a question mid-Turn would park the accept thread, which is the same
sentence as "the whole window freezes". Mid-Turn with an empty cache, `/models`
says the list is not available yet and why, rather than blocking. The cache
itself is never written here: it carries each Model's advertised reasoning
efforts, and a half-shaped entry written from Intercom would reach
`Invoke-DpTurn`.

`/model <n>` writes **two** places, because `Invoke-DpTurn` resolves the
Conversation's own pin before the Settings default and `New-DpConversation` pins
whatever the default was when it was created. Writing only Settings would be a
silent no-op for exactly the Conversation the operator is talking to, and the
reply would name a Model the next instruction was never going to run on. So
`Switch-DpIntercomModel` sets `settings.model` **and** re-pins the bound
Conversation; `/model default` clears both. `Get-DpIntercomModelId` is the single
source for the resolved id, so `/status` and the `<- current` marker in `/models`
cannot disagree.

## Inline keyboards

Reading a numbered list and typing a number is the wrong interaction at a bus
stop. Where a choice is closed, Intercom attaches Telegram's **inline keyboard**
so the operator taps instead - the affordance BotFather uses.

Buttons are offered for **every** question that has options. A Questionnaire is
asked **one question at a time**: DeskPilot sends question 1 with its options as
buttons, the operator taps, question 2 follows, and only when the last is answered
is the whole thing serialized and handed to the bridge - the same single answer
string the browser wizard submits after its own last step. Answering step by step
is a phone affordance, not a second contract.

This exists because the two halves of DeskPilot contradicted each other for a
month. `Initialize-DpQuestionnaireTool` tells the model *"Use ONE call to bundle
all related questions; do not ask them one at a time"*, while Intercom rendered a
keyboard **only** for a lone question - so the affordance was unreachable for
precisely the shape DeskPilot asks the model to produce, and every real
Questionnaire arrived as a wall of numbered text to type a reply to.

- A **single-choice** question ends the step on one tap.
- A **multi-select** question toggles, and its `Done` button closes the step.
  Feedback rides on the tap acknowledgement as a Telegram toast, because
  re-sending the message per tap would cost a call and a queue slot each time and
  editing it needs a message id the outbound queue does not track.
- A **free-text** question has no keyboard and is answered by replying.
- Every list of options also carries **`Something else - type it`**. Tapping it
  makes the next reply the answer, taken verbatim - so a literal "2" stays "2"
  rather than selecting the second choice. This is a deliberate divergence from
  the browser wizard, which honours `allowFreeformInput` strictly:
  `ConvertTo-DpQuestionnaire` defaults that flag to **false** for any question
  that has options, so without the escape hatch most option questions would force
  a wrong answer, and a phone is the worst place to be cornered by one. The
  buttons stay live after it is tapped, so changing one's mind costs nothing. A
  multi-select keeps what was already ticked and adds the words to it; a
  single-choice question is either/or, as it is in the browser.
- Typed text is mapped onto the options first - by the printed number, or an exact
  label - so the old habit of replying "2" still works. Words that match no option
  are refused with the list and a pointer to the escape hatch, rather than sent as
  an answer the browser would not have produced.

The `/chats`, `/agents`, `/models` and `/projects` listings each carry one button
per entry. In every case the text form still works, so nothing depends on the
buttons rendering.

Three constraints shape the design:

- **`callback_data` is capped at 64 bytes**, so it carries a prefix, a nonce and
  an index - never the label. A choice whose data would exceed the cap costs the
  whole keyboard (`Get-DpIntercomKeyboard` returns `$null`) rather than shipping a
  button that fails silently when tapped.
- **Old buttons never disappear.** Telegram leaves them on screen indefinitely, so
  an option tap must carry the nonce of the question *currently* waiting
  (`PendingQuestion.token`). Without it, a tap on a question answered hours ago
  would answer whatever is waiting now. **Each step of an interview mints its own
  nonce**, so a tap on question 1 cannot answer question 2 either.
- **A tap must be acknowledged.** Telegram shows the button as loading until
  `answerCallbackQuery` lands, so it is queued ahead of the reply and bypasses the
  hourly cap - it is a protocol obligation, not a notification. Bare Bot API calls
  ride the same single-send queue as messages, so ordering still holds and nothing
  waits on the accept thread.

`callback_query` is added to `allowed_updates`. A tap is allow-list checked on
`callback_query.message.chat.id` **before its data is read**, exactly as a message
is, and the data is treated as untrusted on arrival even though this bot minted
it: the nonce and the index are both validated before anything happens.

Both answer routes - a written reply and a tap - go through
`Submit-DpIntercomAnswer`, so the acknowledgement, the "that question has gone"
wording and the clearing of the pending question cannot drift apart.

The numbering `/chats` produces is a **snapshot**, not a Conversation property:
the list is ordered by last activity, so running a Turn reorders it. The ids are
remembered in `Intercom.ChatIndex` and `/chat <n>` resolves against them, so the
number the operator saw is the Conversation they get. `/agents`, `/models` and
`/projects` keep the same snapshot in `Intercom.AgentIndex`,
`Intercom.ModelIndex` and `Intercom.ProjectIndex`, for the same reason: the
Agents folder can gain or lose a file, the advertised Model list belongs to the
account rather than to DeskPilot, and a Project can be added at the machine,
between the listing and the tap.

A Project button carries the Project id, which is a short generated token. An
Agent button cannot: an Agent's id is its `*.agent.md` file name, which has no
length bound, and `Get-DpIntercomKeyboard` drops the *whole* keyboard when one
button would exceed the 64-byte cap. It carries the listing's number instead, and
a number the current index no longer backs is refused rather than resolved
against whatever now sits at that position. A Model button carries the number for
the same reason: the id is the provider's string, not one DeskPilot bounds.

Conversation titles are derived from prompts, so `/chats` sends that text to the
Channel. It is metadata rather than content, and it goes only to an allow-listed
chat, but it is not covered by the `sendFinalAnswer` switch - and when `/chats`
is sent from an allow-listed group, that listing is read by everyone in it.

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
| `chatId` | `null` | The operator's own allow-listed Telegram chat |
| `allowGroupChat` | `false` | Whether shared group chats are allow-listed as well |
| `groupChatIds` | `[]` | Their chat ids, always negative, at most ten, and inert while `allowGroupChat` is off. A `groupChatId` string written by an earlier version migrates into this list on load |
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
- `ConvertTo-DpQuestionnaireAnswer` — collected answers become the single string
  the Ask-User bridge takes, in the browser wizard's own wire format.
- `Test-DpIntercomProject` — is the selected Project remote-controllable?

State and transport:

- `Initialize-DpIntercom` — builds the runtime state block and the `HttpClient`.
- `Invoke-DpTelegramRequest` — the one hardened Telegram boundary: HTTPS only,
  bounded response, timeout, token redaction.
- `Send-DpIntercomMessage` — enqueues outbound work behind the rate cap.
- `Update-DpIntercomState` — the pump: reap, dispatch, drain, heartbeat, watch
  for a stall. Never throws into the accept loop.
- `Invoke-DpIntercomCommand` — executes one normalized command.
- `Send-DpIntercomQuestionStep` — sends the one question an interview is on, with
  its keyboard and a fresh nonce.
- `Move-DpIntercomInterview` — advances to the next question, or submits.
- `Read-DpIntercomSecret` / `Save-DpIntercomSecret` — the protected token at
  rest.
- `Get-DpIntercomPayload` — the API projection, with the token removed.
- `Add-DpIntercomLog` — the bounded audit ring.

## See Also

- [Getting started with Intercom](../docs/intercom-getting-started.md)
- [Spec 050 — Security model](050-security-model.md)
- [Spec 020 — Architecture](020-architecture.md)
