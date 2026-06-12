# Spec 080 — New Project / Clone Wizard

> Status: signed off 2026-06-12 (grill-me interview). Companion: spec 070 (Merge
> Wizard). Implementation sequenced **after** the Merge Wizard. Use canonical
> glossary terms only.

## Purpose

Let a non-expert create a **Project** either by cloning a remote repository (SSH
or ambient-credential HTTPS) or by choosing/creating a local-only **Workspace
Folder**, replacing today's bare "Add project..." folder picker with one guided
wizard.

Success: a user clones a repo and starts working in it as a Project without a
terminal.

## Decisions (from the interview)

| Topic | Decision |
| --- | --- |
| Wizard shape | One New Project Wizard; first screen chooses "Clone from a URL" or "Use a local folder". |
| Clone authentication | SSH + the ambient git credential helper only; DeskPilot stores no secrets (no in-app token entry). |
| Destination & naming | Clone into a chosen parent folder; the Project name defaults to the repo basename; auto-select the new Project. |
| Local path | The existing folder picker (Get-DpDirectoryListing / New-DpDirectory), then register as a Project. |

## Non-goals

Storing git credentials or tokens; managing SSH keys; in-app HTTPS token entry;
OAuth/auth providers; sparse / partial / shallow clone options; any post-clone
build or dependency restore.

## Wizard flow

1. Choose "Clone from a URL" or "Use a local folder".
2. Clone path: enter the URL -> choose a parent folder (existing confined picker)
   -> clone via Invoke-DpGitCommand using ambient credentials/SSH -> the Project
   name defaults to the repo basename -> register + auto-select the Project.
3. Local path: today's folder picker -> register as a Project. Local-only
   Projects naturally use spec 070's local-only degrade path.

## Implementation map

Backend:

- `Invoke-DpGitClone` — validate the URL shape; derive the repo basename; clone
  into `<parent>/<name>` via the process-based Invoke-DpGitCommand (no shell);
  never throw; return `{ ok, path, name, error }`.
- Reuse `Get-DpDirectoryListing` / `New-DpDirectory` for the parent-folder pick,
  and the existing Project registry (`Merge-DpSettings`, de-dup guard).

Routes:

- `POST /api/projects/clone` — `{ url, parent, name? }` -> register + select on
  success; `{ error: { code, message } }` otherwise.

Frontend (`web/`): a New Project Wizard modal with the clone-vs-local choice,
reusing the existing modal + folder-picker patterns; progress + result feedback.

## Failure modes & edge cases

git missing -> message. Auth fails (HTTPS with no helper / missing SSH key) ->
surface git's error + guidance (use SSH or set up the helper); nothing
registered. Invalid URL -> reject early. Destination exists / not empty -> refuse
or offer a different name. Network offline / interrupted -> report; offer to
remove the partial folder. Repo-name derivation = last path segment minus `.git`.
Name/path collision with an existing Project -> the existing de-dup guard
surfaces it. Empty repo / unborn HEAD -> register anyway; the Git bar handles it.

## Security

Clone via the process-based Invoke-DpGitCommand (no shell); the URL is a process
argument (no interpolation); the parent-folder pick is confined like the existing
filesystem endpoints. SSH + ambient credentials only; DeskPilot stores no
secrets. Localhost bind + session token unchanged.

## Performance

Clone is long-running and must not block the single-threaded accept loop: run it
off the accept thread with progress/spinner feedback. The single-active-Turn
limit applies to the Engine, not to git.

## Open questions

- Partial-clone cleanup on failure (proposed: offer to delete the partial folder).
- Clone progress percentage vs a plain spinner (depends on parsing
  `git clone --progress` stderr).
- Whether HTTPS repos with no configured helper should ever get a one-time inline
  prompt (currently no).