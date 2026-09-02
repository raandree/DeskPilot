// English resources. This is the source locale AND the fallback: every key that
// exists anywhere must exist here, and tests enforce that both ways.
//
// Keys are dotted and flat (no nesting) so a missing-key check is a set
// comparison rather than a tree walk. A plural key is stored as `<key>.one` /
// `<key>.other`; Intl.PluralRules chooses between them.
//
// Translator notes:
//   - "Engine" is ShellPilot, the local component that talks to GitHub Copilot.
//     "Model" is the LLM. The two must stay distinct in every language.
//   - "Project", "Conversation", "Turn", "Permission", "Intercom", "Skill",
//     "Instruction", "Agent" are product terms from the glossary.
//   - Safety copy (warn.*) must keep its meaning intact. Do not shorten a
//     warning to make it fit a control.

export const en = {
    // Sidebar and navigation
    'app.newConversation': '+ New conversation',
    'app.home.title': 'DeskPilot home — close the current chat',
    'app.home.aria': 'DeskPilot home',
    'app.search.placeholder': 'Search conversations…',
    'app.search.aria': 'Search conversations',
    'nav.customizations': 'Customizations',
    'nav.customizations.title': 'Customizations — agents, skills, instructions, prompts',
    'nav.schedules': 'Open scheduled work',
    'nav.schedules.title': 'Scheduled work',
    'nav.diagnostics': 'Open diagnostics',
    'nav.diagnostics.title': 'Diagnostics',
    'nav.settings': 'Settings',
    'nav.usage.title': 'Credits — this session / all-time',
    'nav.version.title': 'DeskPilot version',

    // Top bar
    'topbar.sidebar': 'Toggle sidebar',
    'topbar.title.aria': 'Conversation title',
    'topbar.model': 'Model',
    'topbar.context.title': 'Context window usage',
    'topbar.context.aria': 'Session info and context window',
    'topbar.intercom.title': 'Intercom — remote control from your phone',
    'topbar.intercom.aria': 'Intercom status',
    'topbar.theme.title': 'Toggle light / dark mode',
    'topbar.theme.aria': 'Toggle light or dark mode',
    'topbar.files': '☰ Files',
    'topbar.files.title': 'Toggle the project files panel',
    'topbar.files.aria': 'Toggle files',

    // Empty state
    'empty.heading': 'How can I help?',
    'empty.body': 'Ask a question, or give the agent a task. It can read and write files, run commands, and browse — with the permissions you allow.',

    // Composer
    'composer.permissions': 'Permissions',
    'composer.permissions.title': 'Tool permissions',
    'composer.project.title': 'Project — the working folder for new prompts',
    'composer.project.none': 'No project',
    'composer.agent.title': 'Agent — the persona the assistant uses',
    'composer.agent.none': 'No agent',
    'composer.attach': '📎 Attach',
    'composer.attach.title': 'Attach files',
    'composer.insert': '＋ Insert',
    'composer.insert.title': 'Insert a prompt file or reference a project file',
    'composer.dictate': '🎤 Dictate',
    'composer.dictate.title': 'Dictate (speech to text)',

    // Sign-in
    'auth.title': 'Connect to GitHub Copilot',
    'auth.subtitle': 'DeskPilot uses your GitHub Copilot account through the local ShellPilot engine. Sign in once to get started.',
    'auth.connect': 'Connect',
    'auth.recheck': "I've signed in elsewhere",
    'auth.hint.privacy': 'Nothing leaves your machine except the calls the engine already makes to GitHub.',

    // Scheduled work
    'schedules.title': 'Scheduled work',
    'schedules.close': 'Close scheduled work',
    'schedules.intro': 'A schedule runs its prompt in its own conversation when DeskPilot is running and nothing else is using the agent. Terminal access is switched off for an unattended run unless you choose otherwise, because nobody is at the machine to approve a command.',
    'schedules.empty': 'No schedules yet.',
    'schedules.queueEmpty': 'No runs are waiting.',
    'schedules.queue.one': '{count} run is waiting for the agent to become free.',
    'schedules.queue.other': '{count} runs are waiting for the agent to become free.',
    'schedules.form.add': 'Add a schedule',
    'schedules.form.edit': 'Edit schedule',
    'schedules.name': 'Name',
    'schedules.prompt': 'Prompt',
    'schedules.repeats': 'Repeats',
    'schedules.repeats.daily': 'Every day',
    'schedules.repeats.weekly': 'Selected weekdays',
    'schedules.repeats.once': 'Once',
    'schedules.time': 'At (local time)',
    'schedules.date': 'Date',
    'schedules.weekdays': 'Weekdays',
    'schedules.project': 'Project',
    'schedules.busy': 'If DeskPilot is busy',
    'schedules.busy.queue': 'Wait and run when free',
    'schedules.busy.skip': 'Skip this run',
    'schedules.permissions': 'Permissions',
    'schedules.permissions.safe': 'Safe — no terminal commands',
    'schedules.permissions.live': 'Current permissions, including terminal',
    'schedules.save.add': 'Add schedule',
    'schedules.save.edit': 'Save schedule',
    'schedules.cancel': 'Cancel',
    'schedules.runNow': 'Run now',
    'schedules.pause': 'Pause',
    'schedules.resume': 'Resume',
    'schedules.edit': 'Edit',
    'schedules.delete': 'Delete',
    'schedules.next': 'Next: {when}',
    'schedules.paused': 'Paused',
    'schedules.waiting': 'waiting to run',
    'schedules.last': 'Last: {outcome} — {detail}',
    'schedules.everyDay': 'Every day at {time}',
    'schedules.onDays': '{days} at {time}',
    'schedules.queued': 'Queued. It runs as soon as the agent is free.',
    'schedules.added': 'Schedule added.',
    'schedules.saved': 'Schedule saved.',

    // Diagnostics
    'diagnostics.title': 'Diagnostics',
    'diagnostics.close': 'Close diagnostics',
    'diagnostics.selfCheck': 'Run self-check',
    'diagnostics.supportBundle': 'Create support bundle',
    'diagnostics.versions': 'Versions',
    'diagnostics.paths': 'Resolved paths',
    'diagnostics.checks': 'Self-check',
    'diagnostics.log': 'Host Server log',
    'diagnostics.clearLog': 'Clear log',

    // Settings
    'settings.language': 'Language',
    'settings.language.auto': 'Match my system',
    'settings.language.en': 'English',
    'settings.language.de': 'Deutsch',

    // Safety copy. Meaning over brevity.
    'warn.schedule.live': 'This schedule will run unattended with your current permissions, including terminal commands, and nobody will be there to approve them. Continue?',
    'warn.schedule.delete': 'Delete the schedule "{name}"? Conversations it already created are kept.',
    'warn.conversation.delete': 'Delete this conversation? This cannot be undone.',
    'warn.changes.discard': 'Discard every listed change? A file the agent created and you never saved is deleted, and there is no other copy of it anywhere.',
    'warn.update.install': 'Install this update? DeskPilot and the engine are replaced on your machine, and DeskPilot restarts to finish.',
    'warn.terminal.enable': 'Terminal access lets the agent run commands on this computer, including commands that change or delete files. Only turn it on if you understand what you are asking for.',

    // Server errors, by stable code. The wire contract never changes with the
    // language; only what the reader is shown does.
    'error.busy': 'DeskPilot is working on something. Try again once it finishes.',
    'error.not_found': 'That item no longer exists.',
    'error.bad_schedule': 'That schedule is not valid: {message}',
    'error.already_queued': 'A run for this schedule is already waiting.',
    'error.queue_full': 'The run queue is full. Try again once it drains.',
    'error.too_many_schedules': 'DeskPilot keeps at most 50 schedules. Delete one first.',
    'error.auth_required': 'Your sign-in has expired. Sign in again to continue.',
    'error.engine_unavailable': 'The engine is not available. Check Diagnostics.',
    'error.too_large': 'That file is too large to send.',
    'error.executable': 'DeskPilot never opens a program or script outside itself.',
    'error.no_workspace': 'Choose a project first.',
    'error.unknown': 'Something went wrong.',
};
