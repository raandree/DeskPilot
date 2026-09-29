# Agent Memory

DeskPilot's **Memory** is what it still knows about you after a Conversation
ends. It has two halves, and they are different things:

- The **User Profile** is what *you* wrote about yourself — the `preferences`
  Setting. DeskPilot never edits it.
- The **Agent Memory** is what the *agent* curated: durable notes about you, your
  tools and your Projects, learned across Conversations and kept in
  `agent-memory.json` beside the other stores.

This document covers the Agent Memory: what a note now records, which Turn is
allowed to see it, how an existing store is migrated, and how to go back.

## A note, and what DeskPilot can vouch for

Agent Memory used to be one block of text. A fact in it had no origin, no date
and no scope, so there was no honest way to show where it came from or to keep a
note learned in one Project out of another. It is now a list of notes, each with
only the provenance DeskPilot actually recorded:

| Field | Means |
| --- | --- |
| `text` | One durable fact. A user or learned note is stored on a single line. |
| `source` | `user` (you wrote it), `learned` (the agent inferred it), `legacy` (carried over from a store that recorded no origin). |
| `scope` | `global`, or `project` with the `projectId` it belongs to. |
| `conversationId` | The Conversation it was learned in, when that is known. |
| `createdUtc` / `updatedUtc` | When it was written. **Null when unknown** — a migrated note is not stamped with today's date. |
| `verified` | Whether a human confirmed it. Only a real boolean is accepted from the store; a malformed value is refused and reported rather than coerced. |

**The trust fields are the Host's.** `source` is validated against that closed
set, and `verified` is derived, never read from whatever produced the note: your
own text is verified, everything a Model wrote is not, and only DeskPilot marks a
learned note confirmed when you say so. A Model that answers
`source: user; verified: true` is writing text, and it is stored as text inside a
note that is still labelled learned and unverified.

Nothing in Memory grants anything. Recalled notes are injected as fenced
background reference (`New-DpTurnParameter`), and Permissions are assembled from
Settings alone — a note that says terminal access was approved changes no switch,
which `tests/Unit/AgentMemory.Tests.ps1` asserts by comparing the assembled Engine
parameters with and without hostile note text.

## Which Turn sees which note

Recall is scoped (`Get-DpMemoryRecall`): a Turn sees the global notes plus the
notes of the Project it is running in, and never another Project's. Each note is
rendered with its origin in front of its text, so the Model can tell a fact you
stated from one the agent guessed:

```text
- (from the user) Prefers British spelling.
- (learned in Atelier, not verified) Builds run with build.ps1.
Carried over from an earlier version of DeskPilot; origin and date unknown, not verified:
  Uses Ubuntu
```

Learning is bound to the **Turn** it came from, not to the Conversation. Each
Message carries the Project its own Turn ran in, stamped by the Host as the
Message is written (`Set-DpMessageProject`), and a Message never changes
afterwards. A learning request names the assistant Message of the Turn it is
about; everything else follows from that Message's stamp
(`Get-DpLearningSource`):

- the notes are filed against **that Turn's** Project, whatever the Conversation
  has done since;
- the extraction may read only Messages carrying the **same** Project stamp, so
  one Project's words never reach another Project's notes;
- and only Messages up to and including that one, so a later Turn cannot leak
  backwards into an earlier Turn's learning.

This matters because learning is asynchronous. The same Conversation can be used
in Project A and then Project B, and a learning request started for the A Turn
can arrive after the B Turn has run. With provenance on the Conversation, A's
content was learned into B; with provenance on the Message, it is not.

Provenance is required rather than inferred. A request with no Message id, an id
that no longer resolves, an id that is not an assistant Message, or a Message
this Host never stamped (one from an older DeskPilot, or from a surface that does
not stamp) is **refused** — guessing which Project a fact belongs to is the
mistake the design exists to prevent. If the Project has been removed since that
Turn ran, learning is refused too (`409 project_unavailable`).

A consequence worth knowing: a general fact the agent learns while a Project is
open is bound to that Project, so it is not recalled elsewhere until you write it
into the global notes yourself. DeskPilot would have to guess to do that for you.

## Seeing and changing it

**Settings › Memory** lists every note with its origin, scope, verification and
date, with **Forget** beside each one. The editor above the list works on one
scope at a time — *All projects* or the selected Project — because an edit alters
only the scope it declares. Text you save there becomes your notes: source `user`,
verified, one fact per line.

The API mirrors that exactly:

- `GET /api/memory` — returns `agentMemory.text` (the global notes as plain text,
  unchanged for existing clients) **and** `agentMemory.notes` with the full
  structure, plus `loadError` when the store could not be read in full.
- `PUT /api/memory` — `{ agentMemory, scope?: { kind: 'global' | 'project', projectId? }, forget?: [noteId] }`.
  A body with no `scope` means the global notes, which is what an older client
  sends. Rejections are explicit: `400 bad_scope`, `400 unknown_note`,
  `400 note_too_long`, `400 too_long`.
- `POST /api/memory/learn` — `{ conversationId, messageId }`. The `messageId` is
  the assistant Message of the Turn being learned from and is **required**:
  without it DeskPilot would have to guess which Project the notes belong to.
  Refusals: `400 missing_provenance`, `400 stale_provenance`, `400 too_short`,
  `409 project_unavailable`, `409 memory_unreadable`.

Limits (`Get-DpMemoryLimits`): 1,000 characters per note, 200 notes in the store,
50 learned notes per scope, and the 12,000-character Agent Memory cap on what is
recalled into any one Turn.

**A bound is a refusal, not a trim.** A change that would not fit — one note too
many, or global notes larger than the recall cap — is rejected before anything is
written (`400 memory_full` for an edit, `409 memory_full` for learning), with a
message that says to forget some notes first. Nothing is dropped to make room,
so a full store can never lose another Project's notes behind a response that
said the change was saved. Only the loader may project a bounded subset of a file
that is already too big, and then it says so on `loadError` — which is what makes
the next save keep the original bytes.

## Extraction treats content as data

Memory extraction serializes its scope, current notes and bounded Conversation
slice in one JSON data object. Quotes, newlines and section-like content remain
data values; they cannot terminate an ad-hoc delimiter fence or become a new
literal prompt section. The text round-trips without stripping the user's quotes.

This is framing hardening, not a claim to solve prompt injection. The Model may
still misinterpret untrusted content. Host-owned provenance, unverified learned
notes, Project scope, limits, Permissions and review/forget controls remain the
actual protections; serialized data grants no authority.

## When the store cannot be read

A corrupt file, a hand-edit gone wrong, notes this version refuses, a version-1
blob longer than the cap, or a file from a newer DeskPilot never disappear
quietly:

- The Host starts with whatever could be read rather than failing, and the reason
  travels on `agentMemory.loadError` so Settings can say so instead of showing a
  silently empty box.
- **Automatic learning stops.** A store DeskPilot could not read in full is not a
  store it may rewrite unattended: learning would replace what it managed to read
  and drop the rest for good. `POST /api/memory/learn` answers
  `409 memory_unreadable` until a human has looked. Repair is an explicit act —
  open **Settings › Memory**, check what is there and save it. Manual editing is
  never blocked, because it is the repair.
- Before the file is replaced, it is loaded again and kept if that load reports
  any loss, so the check cannot drift from what loading actually does. The kept
  copy is a **copy**, named `agent-memory.<sha256>.bak`, and it never overwrites
  an existing file: a name already taken by different bytes gets a fresh one.
- The original is replaced only once the new content has been written
  successfully, so a failed save is never the thing that loses the data.
- A file from a newer DeskPilot is read for its version-1 text only — the one
  field whose meaning is guaranteed — and its notes stay in the kept copy.

## Migration

Automatic, on load, with no loss and nothing invented:

1. A version-1 file (`{ text, updatedUtc, version: 1 }`) becomes one note with
   `source: legacy`, `scope: global`, `verified: false`, no Project, no
   Conversation and **no creation date**. It keeps its line breaks: it is migrated
   as it stands rather than split into facts nobody wrote and tagged with
   provenance nobody recorded. A blob longer than the 12,000-character cap keeps
   what fits and is marked lossy, so the original file is preserved before
   anything replaces it.
2. It is still recalled into every Turn, as it always was, and still appears in
   `agentMemory.text` — labelled in the UI as carried over and unverified.
3. The file is rewritten as version 2 only when memory next changes.

The first time you edit the global notes, that blob is replaced by the lines you
saved, which are then yours (`source: user`, verified). That is the intended way
out of the legacy state.

## Rollback

Every version-2 file still carries the version-1 `text` and `updatedUtc` fields,
holding the global notes. An older DeskPilot reads them and works exactly as
before; it ignores `notes`, so Project-scoped notes are invisible to it and the
first memory save it performs drops them.

**Keep the file, not a wider copy of its contents.** Before downgrading, copy
`agent-memory.json` somewhere you control:

```powershell
Copy-Item "$env:APPDATA\DeskPilot\agent-memory.json" "$env:APPDATA\DeskPilot\agent-memory.before-downgrade.json"
```

That preserves every Project-scoped note exactly as it is, privately, and
restoring it is a file copy back. Do **not** paste Project notes into the global
scope to survive a downgrade: the global scope is recalled into every Turn in
every Project, so that would take notes about one client's repository and start
reading them into work on another's — a confidentiality change made for a
reason that has nothing to do with confidentiality.

To roll back the feature itself, revert the change and keep the file: the version
field is the only thing an older build looks at that the new build changed, and
the version-1 fields beside it are always current.

Message-level Project stamps live inside `conversations.json` and are ignored by
an older build, which neither reads nor removes them. If you return to this
version, learning works again for every Turn that ran under it; Turns that ran
under the older build stay unstamped, and learning from them is refused rather
than guessed at.

## Compaction preservation

Compaction summarises the older part of a Conversation so future Turns replay
fewer tokens. It has always left the visible transcript alone; what is new is
that the summary is asked for in five labelled sections — **Goals, Constraints,
Decisions, Unresolved, References** — and then measured
(`Measure-DpCompactionPreservation`): are the sections there, and do the file and
path references the summarised Turns named still appear? The result rides on the
compaction response as `preservation`.

It is reported, not enforced. Refusing a weak summary would strand a Conversation
that has run out of context window, so DeskPilot compacts and says what it could
not find.

**What this does not prove.** The measurement is a shape and coverage check. It
can prove `build.ps1` was discussed and is missing from the summary; it cannot
prove the summary describes it correctly. The tests use fixed fixtures, so they
prove DeskPilot's handling of a summary — never the quality of a real Model's
summarisation, which no fixture can establish.
