# Product Context — DeskPilot

## The problem

Agentic knowledge work is powerful but gated behind a steep tool stack. To get
an AI agent that can read your files, run commands, browse, and follow your
house rules, you currently need VS Code + the Copilot extension (or ShellPilot
in a terminal), plus an understanding of instructions, skills, agents, and
version control. Most knowledge workers — the analysts, operators, lawyers, and
researchers the Agentic Operating Model is meant to serve — never get past the
setup.

## The product

DeskPilot is the friendly front door. It looks and feels like a modern AI chat
app with a deep-teal identity of its own: a conversation list on the left, a calm
message thread in the centre, a composer at the bottom. Underneath, every
message drives a real Copilot **agent** through the Engine, with the same tools
VS Code Copilot has.

## Who it is for

| Profile | What they bring | What they want |
| --- | --- | --- |
| Analyst / researcher | Documents, data, questions | "Reason over my corpus and draft the output." |
| Ops engineer / SRE | Runbooks, scripts, a lab | "Run the steps and show me what happened." |
| Lawyer / business | Correspondence, contracts | "Read these, summarise, draft a reply." |
| Curious newcomer | A laptop and a task | "Help me, and teach me the safe way." |

## Experience goals

- **Zero-terminal.** Launch from a desktop shortcut; everything else is in the
  window.
- **Calm and legible.** One primary action at a time. No jargon walls.
- **Show the work.** Tool use is surfaced as an **Activity** panel per Turn —
  what was read, written, run, or fetched — so trust is earned, not assumed.
- **Permissions up front.** A visible Permissions panel; the user can see and
  flip each Tool category, with plain-language descriptions of the risk.
- **Cost is honest.** Token usage, estimated cost, and Copilot credits are
  shown after every Turn.
- **Bring your house rules.** Point DeskPilot at a folder of Skills and
  Instructions and the agent will discover and use them — the same files VS
  Code Copilot uses.

## Primary journeys

1. **First run → authenticate.** Detect missing Copilot token, walk the user
   through the GitHub device-code login from inside the window.
2. **Ask something simple.** Type a question, watch the answer stream in.
3. **Do a tool task.** "Summarise every .md in this folder and write
   summary.md." The agent reads, writes, and reports the Activity.
4. **Tune behaviour.** Pick a cheaper/stronger Model, set the Workspace Folder,
   attach a Skills folder, toggle Permissions.
5. **Review and continue.** Scroll history, branch into a new Conversation,
   check cumulative cost.

## What "done well" looks like

A lawyer with no coding background opens DeskPilot, points it at a folder of
PDFs and a Skills folder her firm provides, and asks it to draft a response
letter — and she can see exactly which files it read and what it wrote, and
stop it at any time.
