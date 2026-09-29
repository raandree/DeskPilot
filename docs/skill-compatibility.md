# Skill compatibility

DeskPilot reads an Agent Skill the way the open specification at
<https://agentskills.io/specification> describes it, and tells you where a
`SKILL.md` disagrees with it. This page is the contract: what DeskPilot reads,
what it deliberately does not, and how to back the feature out.

A **Skill** is a folder holding a `SKILL.md`, discovered under the Skills roots
you configure in Settings. DeskPilot browses and edits those files. It does not
decide which Skill an agent loads at runtime — the Engine does that through its
own discovery — so nothing on this page changes what an agent activates.

## Supported subset

DeskPilot reads the frontmatter block and surfaces these fields when a Skill
actually declares them. Nothing is invented: a field the file leaves out is
absent from the API response and from the panel.

| Field | Read | Checked against |
| --- | --- | --- |
| `name` | Yes, required | 1–64 characters, lowercase letters, digits and single hyphens, no leading or trailing hyphen, and equal to the folder name |
| `description` | Yes, required | Non-empty, at most 1024 characters |
| `license` | Yes, optional | Shown as text, capped at 200 characters |
| `compatibility` | Yes, optional | At most 500 characters |
| `metadata` | Yes, optional | A block mapping of string keys to string values; at most 32 entries, each capped at 200 characters |
| `allowed-tools` | Yes, optional | A single space-separated string. **Descriptive only** |

`version` and `origin` come from the `metadata` mapping (`version`, and
`origin`, `author` or `source` for origin). A top-level `version` or `author` —
common in older Skills — is still shown, with a note that the specification
keeps extra fields under `metadata`.

The body of the `SKILL.md` is not part of this. The catalog carries metadata
only; the Markdown body loads when you open the file, and files under
`references/`, `scripts/` and `assets/` are never opened by the scan at all.
DeskPilot reports only whether those folders exist.

### `allowed-tools` is metadata, not authority

`allowed-tools` is experimental in the specification, and in DeskPilot it grants
nothing. It is copied into the response marked `allowedToolsAuthoritative:
false`, displayed with a note saying so, and read by no code that decides what
an agent may run. What the agent may do stays with your Permission settings. A
Skill that declares `allowed-tools: Bash(rm:*)` gets no terminal access from
that line, and a test in `tests/Unit/SkillConformance.Tests.ps1` fails if any
other part of the repository starts reading the field.

## What DeskPilot reports

Every problem is a code with a severity. An `error` means the file is not a
valid Skill; a `warning` means it is valid but wrong somewhere; `info` is
advice. All of them are localized in `source/web/assets/locales`.

| Code | Severity | Meaning |
| --- | --- | --- |
| `unreadable` | error | The `SKILL.md` could not be read |
| `path-outside-root` | error | The file is not inside the configured folder. Refused before anything was opened |
| `link-below-root` | error | The file, or a folder between it and the root, is a link. Refused before anything was opened |
| `frontmatter-missing` | error | No leading `---` block |
| `frontmatter-malformed` | error | The block is never closed |
| `name-missing` | error | No `name`; the folder name is shown instead |
| `description-missing` | error | No `description`, or an empty one |
| `name-invalid` | warning | Characters the specification does not allow |
| `name-too-long` | warning | Over 64 characters |
| `name-directory-mismatch` | warning | `name` and folder disagree |
| `description-too-long` | warning | Over 1024 characters |
| `compatibility-too-long` | warning | Over 500 characters |
| `value-not-a-scalar` | warning | A field that must hold a plain string holds a list, a mapping or an unfolded block. Not shown |
| `metadata-not-a-map` | warning | `metadata` is not a block mapping |
| `metadata-value-not-a-string` | warning | An entry holds a list or a nested mapping |
| `metadata-too-many-entries` | warning | More entries than DeskPilot shows |
| `allowed-tools-not-a-string` | warning | Declared as a sequence or a mapping |
| `value-control-characters` | warning | Control characters were removed before display |
| `file-too-large` | warning | Larger than the scan limit |
| `frontmatter-too-long` | warning | More frontmatter lines than the scan limit |
| `duplicate-name` | warning | Another Skill answers to the same name |
| `allowed-tools-not-a-permission` | info | The field was declared; it grants nothing |
| `field-unsupported` | info | Frontmatter fields the specification does not define |
| `description-terse` | info | The description reads as a label rather than a trigger |

A Skill that breaks a rule stays listed, readable and editable. Diagnostics
exist so you can repair a file, which is impossible if it disappears from the
list. A Skill refused for a link is listed too — under its folder name, with no
content from the link's target.

### What `conformant` means

`conformant` is `false` whenever DeskPilot **found** a violation or could not
interpret what it read. It is decided by the findings themselves, not by the
diagnostics that fit in the response: a finding that was deduplicated, or that
fell past the 12-diagnostic display budget, still decides the verdict. Content
DeskPilot could not read in full — an oversized file, a truncated frontmatter —
is never certified, because it was never checked.

Informational advice never fails a Skill. A terse description, a declared
`allowed-tools` and a field the specification does not define all leave
`conformant` at `true`.

`duplicate-name` is raised by the catalog, not by the file check, and does not
change `conformant`: the file may conform perfectly while the folder layout is
ambiguous.

### Links are refused, not followed

Confinement is proved before anything is opened, from path text and directory
metadata alone. Two things are settled first:

1. **The file is inside the configured root.** Paths are compared
   case-insensitively on Windows and exactly on every other platform, including
   macOS — a macOS volume *can* be formatted case-sensitively, and a confinement
   boundary cannot rest on a default. Where the two differ, the conservative
   answer wins: a case-spelling alias of a folder is refused rather than read.
   A path outside the root is refused as `path-outside-root`.
2. **Nothing between the root and the file is a link.** Every symlink, junction
   and mount point below the root is refused as `link-below-root`, wherever it
   points.

The second rule is deliberately blunt. Accepting a link means proving the whole
physical chain of its target, and a target that reads as though it were inside
the root can be routed straight back out by another link along the way — a
`SKILL.md` linked to `<root>/relay/SKILL.md` escapes if `relay` is itself a
junction. Refusing needs no read of the target at all, which is the point: a
refused Skill comes back as a diagnostic and nothing else — no name, no
description, no metadata, no resource probe. Tests hold the external target open
exclusively and assert the refusal arrives anyway, which is only possible if
nothing was opened.

The configured root itself is exempt. A root that is a junction or a symlink is
a decision you made in Settings — the CopilotAtelier layout relies on exactly
that — so it is honoured, and only what lies *below* it is checked.

Not every reparse point is a link. A cloud placeholder — a OneDrive
Files On-Demand file — carries the same attribute without redirecting anywhere,
so the link *kind* decides, and an ordinary Skill in a synced folder is read
normally. An entry whose kind cannot be read at all is refused rather than
assumed harmless.

If a Skill genuinely lives outside the root, configure the folder it lives in as
a Skills folder. DeskPilot will not reach out through a link on its own.

### Duplicate names

Two Skills can share a name across overlapping roots. DeskPilot lists both,
marks the copy in the earlier configured root `primary` and the later one
`shadowed`, and says so on each. That is DeskPilot's listing order only. Which
Skill an agent actually loads is decided by the Engine's discovery over the
paths it is given, and DeskPilot does not claim to change it.

## Limitations

- **Not a YAML engine.** Frontmatter parsing is the same minimal, line-based
  reader every Customization uses. Block mappings of scalars are read, and a
  folded or literal block `description` is folded by that reader. Any other
  form — a flow sequence, a flow mapping, an unfolded block scalar on `name`,
  `license`, `compatibility` or `allowed-tools`, an anchor, a multi-document
  file, a tagged value — is reported as `value-not-a-scalar` (or the field's own
  code) and **dropped**, rather than shown as if it were text. Nothing was added
  here to interpret those forms.
- **Bounded by design.** At most 64 KiB of a `SKILL.md` head is read, 200
  frontmatter lines scanned, 32 metadata entries copied and 12 diagnostics
  returned per Skill. A file past a limit is flagged, not silently trimmed, and
  is not certified as conformant.
- **Desktop catalog only.** This is what the Customizations surface shows.
  It does not alter Engine Skill discovery, which the Engine performs itself.
- **A refused Skill shows nothing.** A Skill behind a link below the root, or at
  a path outside it, is listed under its folder name with a diagnostic and no
  content. Links are never followed, even when the target would have been
  legitimate: if the Skill really lives elsewhere, configure that folder as a
  root instead. Nothing is adopted on DeskPilot's initiative.
- **No folder is adopted on its own.** Only configured roots are scanned.
  DeskPilot does not go looking for `.claude/`, `.agents/` or any other
  convention folder unless you configure it.
- **Hard links are indistinguishable.** Confinement is proved through link kind
  (symlinks, junctions, mount points), which is what a link out of a root
  actually is. A hard link has no such marker and cannot be told apart from the
  file it shares — it also has to be created inside your own configured root, on
  the same volume, by something already able to write there.
- **A case-spelling alias is refused off Windows.** Comparison is exact on every
  platform except Windows, so on a case-insensitive volume elsewhere — a default
  macOS one, say — a root configured as `Skills` will not match a path spelled
  `skills`. Spell the configured root the way the folder is spelled on disk. The
  alternative is worse: a case-blind comparison would read a genuinely different
  directory on a case-sensitive volume.
- **Description checks are mechanical.** Length and emptiness are measured.
  `description-terse` is advice about how a description reads, not a measurement
  of how often a Skill triggers.

### Measuring trigger behaviour

No trigger-rate improvement is claimed here: it is not measured, because no such
run was made. To measure it, use the existing eval harness rather than inferring
from the diagnostics:

```powershell
# Score a case set against a live run (see tests/live/eval/README.md)
./tests/live/eval/Invoke-DpParityEval.ps1 -CasePath ./tests/live/eval/cases
```

Compare runs before and after a description change. Until such a run exists, a
rewritten description is an improvement in clarity only.

## Migration and rollback

Nothing has to be migrated. Every existing Skill keeps working, every existing
`GET /api/customizations` field keeps its meaning, and the conformance fields
(`metadata`, `resources`, `warnings`, `conformant`, `precedence`, `directory`)
are additions on skill items only. A client that ignores them sees the list it
saw before. Roots, path confinement and file patterns are unchanged.

To bring an existing Skill into line:

1. Rename the folder, or the `name`, so the two match.
2. Lowercase the `name` and replace anything that is not a letter, a digit or a
   single hyphen.
3. Give the `description` both halves: what the Skill does, and when to use it.
4. Move anything that is not a specification field under `metadata`.
5. Resolve duplicate names by renaming one copy or removing a root.

To roll back, revert the commit. The feature is additive and carries no state:
no setting is written, no file on disk is touched by the scan, and no migration
needs undoing. Dropping `Get-DpSkillConformance` and its call in
`Get-DpCustomizationList` returns the catalog to name, description, path, root
and scope.
