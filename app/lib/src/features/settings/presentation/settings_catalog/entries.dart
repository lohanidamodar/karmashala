part of '../settings_catalog.dart';

// Every option a settings search can land on.

/// Every option on the settings screen. Labels are the words on screen;
/// keywords are lower-case.
const settingsEntries = <SettingsEntry>[
  SettingsEntry(
    'Start at login',
    anchor: SettingsAnchor.startup,
    description: 'Launch Karmashala automatically when you sign in.',
    keywords: ['autostart', 'boot', 'login'],
  ),
  SettingsEntry(
    'Close to tray',
    anchor: SettingsAnchor.startup,
    description: 'Hide to the system tray instead of quitting.',
    keywords: ['tray', 'quit', 'background'],
  ),
  SettingsEntry(
    'Keep system awake',
    anchor: SettingsAnchor.startup,
    description: 'Stop the display and system sleeping while Karmashala runs.',
    keywords: ['sleep', 'keep awake', 'caffeinate'],
  ),
  SettingsEntry(
    'Open agent sessions in chat view',
    anchor: SettingsAnchor.sessionView,
    description: 'Terminal sessions show their chat first.',
    keywords: ['chat', 'terminal', 'phone', 'default'],
  ),
  SettingsEntry(
    'Resume and start sessions in the background',
    anchor: SettingsAnchor.sessionView,
    description: 'No tab opens when you resume or start a session.',
    keywords: ['resume', 'start', 'background', 'tab', 'palette', 'dashboard'],
  ),
  SettingsEntry(
    'Launcher hotkey',
    anchor: SettingsAnchor.launcherHotkey,
    description: 'A global shortcut that brings Karmashala forward.',
    keywords: ['hotkey', 'shortcut', 'global', 'summon', 'quick open'],
  ),
  SettingsEntry(
    'Notes',
    anchor: SettingsAnchor.notes,
    description: 'Keep an idea from a conversation and send it back later.',
    keywords: ['note', 'idea', 'save for later'],
  ),
  SettingsEntry(
    'Send notifications',
    anchor: SettingsAnchor.notifications,
    description: 'Tell me when an agent needs me or finishes.',
    keywords: ['alerts', 'toast', 'desktop', 'phone', 'background'],
  ),
  SettingsEntry(
    'Version and build',
    anchor: SettingsAnchor.about,
    description: 'The build line every log starts with, to paste into a bug.',
    keywords: ['version', 'build', 'licences', 'licenses', 'source'],
  ),
  SettingsEntry(
    'Theme',
    anchor: SettingsAnchor.themeText,
    description: 'Follow the system, or stay light or dark.',
    keywords: ['dark', 'light', 'dark mode'],
  ),
  SettingsEntry(
    'UI text size',
    anchor: SettingsAnchor.themeText,
    description: 'Scales every label, menu, dialog and tooltip.',
    keywords: ['text size', 'zoom', 'scale', 'font'],
  ),
  SettingsEntry(
    'Compact density',
    anchor: SettingsAnchor.themeText,
    description: 'Denser lists and controls.',
    keywords: ['density', 'compact', 'roomy'],
  ),
  SettingsEntry(
    'Store changes',
    anchor: SettingsAnchor.notifications,
    description: 'Notify when an app changes on the App Store or Google Play.',
    keywords: ['app store', 'play', 'release', 'review', 'rejected'],
  ),
  SettingsEntry(
    'Read the stores in the background',
    anchor: SettingsAnchor.storeCredentials,
    description: 'How often the server checks the stores on its own.',
    keywords: ['refresh', 'interval', 'poll', 'app store', 'play'],
  ),
  SettingsEntry(
    'Mark a session quiet after',
    anchor: SettingsAnchor.notifications,
    description: 'How long a working session may go with nothing new.',
    keywords: ['quiet', 'stuck', 'hung', 'idle', 'stalled'],
  ),
  SettingsEntry(
    'One sentence per line in chat',
    anchor: SettingsAnchor.themeText,
    description: 'Each sentence of an agent’s reply on its own line.',
    keywords: ['sentence', 'readability', 'chat', 'line breaks'],
  ),
  SettingsEntry(
    'Tools in the More menu',
    anchor: SettingsAnchor.sidePanel,
    description: 'Which tools the context panel’s More menu lists.',
    keywords: [
      'hide',
      'show',
      'context panel',
      'side panel items',
      'more',
      'rail',
      'activity bar',
    ],
  ),
  SettingsEntry(
    'Project details in the sidebar',
    anchor: SettingsAnchor.sidePanel,
    description: 'A second line under each project: folder, branch, state.',
    keywords: [
      'projects',
      'sidebar',
      'explorer',
      'path',
      'branch',
      'compact',
      'rows',
      'density',
    ],
  ),
  SettingsEntry(
    'Wrap long lines in the editor',
    anchor: SettingsAnchor.editor,
    description: 'Soft-wrap instead of scrolling sideways.',
    keywords: ['word wrap', 'soft wrap', 'line numbers'],
  ),
  SettingsEntry(
    'Auto save',
    anchor: SettingsAnchor.editor,
    description: 'Write a file tab without being asked.',
    keywords: ['auto save', 'autosave', 'save', 'unsaved'],
  ),
  SettingsEntry(
    'Auto save delay',
    anchor: SettingsAnchor.editor,
    description: 'How long typing has to pause before the file is written.',
    keywords: ['auto save', 'autosave', 'delay'],
  ),
  SettingsEntry(
    'File picker',
    anchor: SettingsAnchor.fileBrowsing,
    description: 'Which dialog every Browse… opens.',
    keywords: ['browse', 'dialog', 'native dialog', 'picker'],
  ),
  SettingsEntry(
    'Show hidden files',
    anchor: SettingsAnchor.fileBrowsing,
    description: 'Show dot-files and hidden entries in every file browser.',
    keywords: ['hidden', 'dotfiles', 'dot files'],
  ),
  SettingsEntry(
    'Open sessions in',
    anchor: SettingsAnchor.externalTerminal,
    description: 'The terminal app a session resumes in outside Karmashala.',
    keywords: ['terminal app', 'resume', 'iterm', 'wezterm'],
  ),
  SettingsEntry(
    'Open folders in',
    anchor: SettingsAnchor.externalEditor,
    description: 'The editor "Open in editor" hands a folder to.',
    keywords: ['editor', 'vs code', 'code editor', 'cursor', 'zed'],
  ),
  SettingsEntry(
    'Shell new terminals open with',
    anchor: SettingsAnchor.defaultTerminal,
    description: 'The default terminal profile.',
    keywords: ['shell', 'profile', 'powershell', 'bash', 'zsh', 'wsl'],
  ),
  SettingsEntry(
    'Resume running panes on launch',
    anchor: SettingsAnchor.defaultTerminal,
    description: 'Start again what was running when the app last closed.',
    keywords: ['restore', 'resume', 'restart'],
  ),
  SettingsEntry(
    'Terminal font size',
    anchor: SettingsAnchor.terminalFont,
    description: 'The terminal grid’s font size, apart from the UI text size.',
    keywords: ['font', 'size', 'zoom'],
  ),
  SettingsEntry(
    'Terminal colours',
    anchor: SettingsAnchor.terminalTheme,
    description:
        'Match the app, pick a built-in scheme, or use a Ghostty or Warp '
        'theme found on this machine.',
    keywords: [
      'terminal',
      'colour',
      'color',
      'colors',
      'scheme',
      'theme',
      'palette',
      'ansi',
      'dracula',
      'nord',
      'solarized',
      'gruvbox',
      'tokyo night',
      'one dark',
      'monokai',
      'ghostty',
      'warp',
    ],
  ),
  SettingsEntry(
    'Keyboard shortcuts',
    anchor: SettingsAnchor.keyboard,
    description: 'Every binding in force, and the keymap.json that moves them.',
    keywords: ['keymap', 'shortcuts', 'rebind', 'keybindings', 'unbind'],
  ),
  SettingsEntry(
    'Terminal chords',
    anchor: SettingsAnchor.terminalChords,
    description: 'Which shortcuts a focused terminal gives back to the app.',
    keywords: ['chords', 'keys', 'keyboard', 'shortcuts', 'ctrl'],
  ),
  SettingsEntry(
    'Shell integration',
    anchor: SettingsAnchor.terminalAdvanced,
    description: 'Mark where commands start and end, for exit codes.',
    keywords: ['osc 133', 'exit codes', 'command blocks'],
  ),
  SettingsEntry(
    'Server status',
    anchor: SettingsAnchor.serverStatus,
    description:
        'Whether this machine\'s server runs. Its shells survive a crash or a '
        'restart of the app.',
    keywords: ['session host', 'karmashala_host', 'persistent', 'uptime'],
  ),
  SettingsEntry(
    'Restart or stop the server',
    anchor: SettingsAnchor.serverStatus,
    description: 'Each asks first, naming the sessions it ends.',
    keywords: ['restart', 'stop', 'session host'],
  ),
  SettingsEntry(
    'Keep sessions running when Karmashala quits',
    anchor: SettingsAnchor.serverStatus,
    description:
        'Terminals and agents in the server go on after the app closes.',
    keywords: ['quit', 'background', 'session host', 'keep running'],
  ),
  SettingsEntry(
    'Server log',
    anchor: SettingsAnchor.serverLog,
    description:
        'Where this machine\'s server writes its log, opened in an app or '
        'in Logs.',
    keywords: ['server.log', 'logs', 'troubleshoot', 'report'],
  ),
  SettingsEntry(
    'Database size',
    anchor: SettingsAnchor.serverStorage,
    description:
        'How much the server\'s database holds, and its largest '
        'tables.',
    keywords: ['database', 'sqlite', 'disk', 'size', 'tables'],
  ),
  SettingsEntry(
    'Tool-image cache',
    anchor: SettingsAnchor.serverStorage,
    description:
        'Pictures agents\' tools answered with: how many, how long they are '
        'kept, the size cap, and Clear.',
    keywords: ['tool images', 'screenshots', 'cache', 'clear', 'disk'],
  ),
  SettingsEntry(
    'Clean up old ended sessions',
    anchor: SettingsAnchor.serverStorage,
    description:
        'Delete ended sessions older than a number of days, when '
        'you ask.',
    keywords: ['old sessions', 'clean up', 'delete', 'purge', 'ended'],
  ),
  SettingsEntry(
    'Keep the timeline for',
    anchor: SettingsAnchor.serverStorage,
    description:
        'How many days of the activity log the timeline is drawn '
        'from to keep; forever by default.',
    keywords: ['timeline', 'activity', 'history', 'retention', 'overview'],
  ),
  SettingsEntry(
    'Worktree setup',
    anchor: SettingsAnchor.worktreeSetup,
    description: 'What to copy and run in a checkout’s new worktree.',
    keywords: ['worktree', 'post create', 'gitignored'],
  ),
  SettingsEntry(
    'What can be built',
    anchor: SettingsAnchor.appProjects,
    description: 'What a checkout is detected as, and what it builds.',
    keywords: ['app projects', 'flutter', 'react native', 'project kinds'],
  ),
  SettingsEntry(
    'Slim emulators when they start',
    anchor: SettingsAnchor.androidEmulators,
    description: 'Switch off what an Android emulator does not need.',
    keywords: ['slimming', 'memory', 'ram', 'processes', 'android'],
  ),
  SettingsEntry(
    'Emulator renderer',
    anchor: SettingsAnchor.androidEmulators,
    description: 'The GPU mode an emulator is started with.',
    keywords: ['gpu', 'swiftshader', 'host gpu', 'black preview'],
  ),
  SettingsEntry(
    'What emulator slimming applies',
    anchor: SettingsAnchor.androidEmulators,
    description: 'Launch flags, animations and packages, one group at a time.',
    keywords: ['packages', 'animations', 'flags', 'categories'],
  ),
  SettingsEntry(
    'Slim simulators when they start',
    anchor: SettingsAnchor.iosSimulators,
    description: 'Switch off the background services a simulator boots.',
    keywords: ['slimming', 'memory', 'boot', 'services', 'xcode'],
  ),
  SettingsEntry(
    'Simulator services kept running',
    anchor: SettingsAnchor.iosSimulators,
    description: 'Groups a slimmed simulator leaves on.',
    keywords: [
      'keep running',
      'push notifications',
      'photo picker',
      'universal links',
    ],
  ),
  SettingsEntry(
    'Command snippets',
    anchor: SettingsAnchor.snippets,
    description: 'Saved commands to insert into a terminal.',
    keywords: ['snippet', 'saved command', 'library'],
  ),
  SettingsEntry(
    'GitHub token',
    anchor: SettingsAnchor.github,
    description:
        'The token GitHub features use, saved on the server, and which gh '
        'account each host uses.',
    keywords: ['github', 'token', 'gh auth', 'enterprise', 'account'],
  ),
  SettingsEntry(
    'Load these in new terminals',
    anchor: SettingsAnchor.variables,
    description:
        'Environment variables and secrets every terminal starts '
        'with.',
    keywords: ['env', 'secret', 'token', 'api key', 'wslenv'],
  ),
  SettingsEntry(
    'Automations',
    anchor: SettingsAnchor.automations,
    description:
        'Agent runs on a schedule, an event or a webhook, in their own tab.',
    keywords: [
      'automation',
      'webhook',
      'cron',
      'nightly',
      'schedule',
      'event',
      'project check',
    ],
  ),
  SettingsEntry(
    'Scheduled resumes',
    anchor: SettingsAnchor.automations,
    description:
        'Sessions waiting to be resumed when their usage window resets.',
    keywords: ['resume', 'pending', 'cancel', 'reset', 'limit'],
  ),
  SettingsEntry(
    'When an agent hits its usage limit',
    anchor: SettingsAnchor.automations,
    description:
        'Resume automatically at the reset (the default), ask first, or do '
        'nothing — where automatic resume is turned off.',
    keywords: [
      'usage limit',
      'rate limit',
      'automatic resume',
      'auto resume',
      'turn off',
      'codex',
      'claude',
    ],
  ),
  SettingsEntry(
    'Continue turns cut off when the session host stops',
    anchor: SettingsAnchor.automations,
    description:
        'A turn running when the session host stopped or crashed is resumed '
        'when it starts again.',
    keywords: [
      'restart',
      'crash',
      'continue',
      'cut off',
      'interrupted',
      'session host',
    ],
  ),
  SettingsEntry(
    'Default resume message',
    anchor: SettingsAnchor.automations,
    description: 'What a resumed session is told, unless you say otherwise.',
    keywords: ['continue', 'message', 'prompt'],
  ),
  SettingsEntry(
    'Agent for new sessions',
    anchor: SettingsAnchor.defaultAgent,
    description: 'Pre-selected when starting a session.',
    keywords: ['default agent', 'new session', 'pre-selected'],
  ),
  SettingsEntry(
    'Default model',
    anchor: SettingsAnchor.defaultModel,
    description: 'The model new sessions on each agent start on.',
    keywords: ['model', 'opus', 'sonnet', 'gpt'],
  ),
  SettingsEntry(
    'Detection',
    anchor: SettingsAnchor.detection,
    description: 'Search every environment for installed agent CLIs again.',
    keywords: [
      'detect',
      'detect agents',
      'rescan',
      'scan',
      'install',
      'claude',
      'codex',
      'antigravity',
    ],
  ),
  SettingsEntry(
    'Executable path',
    anchor: SettingsAnchor.executables,
    description: 'Where each agent CLI lives, and whether it still opens.',
    keywords: ['path', 'executable', 'not found', 'repoint'],
  ),
  SettingsEntry(
    'Automatic checkpoints',
    anchor: SettingsAnchor.checkpoints,
    description: 'Snapshot every agent turn, and how many snapshots to keep.',
    keywords: ['checkpoint', 'rewind', 'undo', 'retention', 'keep'],
  ),
  SettingsEntry(
    'Let agents update themselves in Karmashala sessions',
    anchor: SettingsAnchor.agentUpdates,
    description:
        'Off on Windows by default: a self-updating CLI under an unsigned '
        'app can trip behavioural antivirus. Update each agent from here '
        'instead.',
    keywords: [
      'update',
      'self-update',
      'auto-update',
      'antivirus',
      'bitdefender',
      'disable_autoupdater',
      'check_for_update_on_startup',
    ],
  ),
  SettingsEntry(
    'Claude Code accounts',
    anchor: SettingsAnchor.claudeAccounts,
    description: 'Signed-in and saved Claude Code accounts.',
    keywords: ['claude', 'login', 'sign in', 'switch account'],
  ),
  SettingsEntry(
    'Codex accounts',
    anchor: SettingsAnchor.codexAccounts,
    description: 'Signed-in and captured Codex accounts.',
    keywords: ['codex', 'openai', 'login'],
  ),
  SettingsEntry(
    'Usage & limits',
    anchor: SettingsAnchor.usage,
    description: 'How much of each agent’s limit is left.',
    keywords: ['usage', 'limits', 'quota', 'rate limit'],
  ),
  SettingsEntry(
    'Permission mode',
    anchor: SettingsAnchor.permissionModes,
    description: 'What new and existing sessions may do without asking.',
    keywords: ['ask', 'bypass', 'accept edits', 'approval', 'sandbox'],
  ),
  SettingsEntry(
    'Run JavaScript in the page',
    anchor: SettingsAnchor.browser,
    description: 'Allow browser_evaluate, per project.',
    keywords: ['browser_evaluate', 'javascript', 'cookies', 'consent'],
  ),
  SettingsEntry(
    'MCP bridge',
    anchor: SettingsAnchor.mcpBridge,
    description: 'Whether an agent can reach Karmashala, measured.',
    keywords: ['mcp', 'control server', 'hooks', 'status callbacks'],
  ),
  SettingsEntry(
    'Agent tools',
    anchor: SettingsAnchor.toolCatalogue,
    description: 'Every tool the bridge serves, by family.',
    keywords: ['tools', 'tool list', 'catalogue'],
  ),
  SettingsEntry(
    'Skills',
    anchor: SettingsAnchor.skills,
    description: 'The skills written into each agent CLI here.',
    keywords: ['skills', 'second opinion', 'instructions'],
  ),
  SettingsEntry(
    'Execution environments',
    anchor: SettingsAnchor.executionEnvironments,
    description:
        'This computer, WSL distributions and other places work '
        'runs.',
    keywords: ['wsl', 'windows', 'local', 'discover'],
  ),
  SettingsEntry(
    'SSH hosts',
    anchor: SettingsAnchor.sshHosts,
    description: 'Hosts reached over SSH, each one an environment.',
    keywords: ['ssh', 'server', 'remote build'],
  ),
  SettingsEntry(
    'Pair a phone with an SSH host',
    anchor: SettingsAnchor.sshHosts,
    description:
        'A QR, or an address and a code, that connects the companion '
        'straight to the machine.',
    keywords: ['pair phone', 'qr', 'companion', 'phone', 'pairing', 'scan'],
  ),
  SettingsEntry(
    'Flutter SDK',
    anchor: SettingsAnchor.flutterSdk,
    description: 'Which flutter each environment uses.',
    keywords: ['flutter', 'sdk', 'dart'],
  ),
  SettingsEntry(
    'Build tooling',
    anchor: SettingsAnchor.buildTooling,
    description: 'What each machine can build with.',
    keywords: ['toolchain', 'android sdk', 'xcode', 'jdk'],
  ),
  SettingsEntry(
    'Trusted host keys',
    anchor: SettingsAnchor.knownHosts,
    description: 'SSH host keys you have accepted.',
    keywords: ['known hosts', 'fingerprint', 'keys'],
  ),
  SettingsEntry(
    'Machines',
    anchor: SettingsAnchor.machines,
    description:
        'The Karmashala server this window uses: this computer\'s, or one '
        'on another machine.',
    keywords: ['machine', 'server', 'add a machine', 'droplet', 'switch'],
  ),
  SettingsEntry(
    'Remote access',
    anchor: SettingsAnchor.remoteAccess,
    description: 'Let a paired phone view and answer sessions.',
    keywords: ['companion', 'phone', 'pairing', 'mobile'],
  ),
  SettingsEntry(
    'Local relay',
    anchor: SettingsAnchor.remoteAccess,
    description: 'A relay on this computer for phones on the same network.',
    keywords: ['relay', 'port', 'lan'],
  ),
  SettingsEntry(
    'Hosted relay',
    anchor: SettingsAnchor.remoteAccess,
    description: 'Reach a phone anywhere through an internet relay.',
    keywords: ['relay', 'relay url', 'internet'],
  ),
  SettingsEntry(
    'Use an SSH host as a relay',
    anchor: SettingsAnchor.remoteAccess,
    description:
        'Run the relay on a machine of your own, so phones meet this '
        'desktop there.',
    keywords: ['relay', 'ssh relay', 'ssh', 'self-hosted', 'own server', 'box'],
  ),
  SettingsEntry(
    'App Store Connect key',
    anchor: SettingsAnchor.storeCredentials,
    description: 'The team API key the Stores tab reads the App Store with.',
    keywords: [
      'app store',
      'apple',
      'p8',
      'issuer',
      'vendor number',
      'testflight',
    ],
  ),
  SettingsEntry(
    'Google Play service account',
    anchor: SettingsAnchor.storeCredentials,
    description:
        'The service-account key the Stores tab reads Google Play with.',
    keywords: [
      'google play',
      'play console',
      'service account',
      'json',
      'reports bucket',
      'package name',
    ],
  ),
  SettingsEntry(
    'Debug mode',
    anchor: SettingsAnchor.debugMode,
    description: 'Record fine detail and add Logs to the activity strip.',
    keywords: ['debug', 'verbose', 'logs panel', 'logs'],
  ),
  SettingsEntry(
    'Lines kept in memory',
    anchor: SettingsAnchor.debugMode,
    description: 'How many lines the Logs tab keeps.',
    keywords: ['buffer', 'log lines'],
  ),
  SettingsEntry(
    'Write a log file',
    anchor: SettingsAnchor.logFile,
    description: 'A log that survives a crash, for a bug report.',
    keywords: ['logs', 'log file', 'report', 'troubleshoot', 'verbosity'],
  ),
  SettingsEntry(
    'Scrollback persistence',
    anchor: SettingsAnchor.scrollbackPersistence,
    description: 'Whether terminal scrollback is written as fast as it grows.',
    keywords: ['scrollback', 'autosave'],
  ),
  SettingsEntry(
    'Session watching',
    anchor: SettingsAnchor.sessionWatching,
    description: 'How many sessions are watched, and how fresh they are.',
    keywords: ['watch', 'hooks', 'probe'],
  ),
  SettingsEntry(
    'Memory footprint',
    anchor: SettingsAnchor.memoryFootprint,
    description: 'What the app is holding, and how much of it is scrollback.',
    keywords: ['memory', 'ram', 'leak', 'resident', 'scrollback'],
  ),
];
