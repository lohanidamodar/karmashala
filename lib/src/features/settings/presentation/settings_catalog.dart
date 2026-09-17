import 'package:flutter/widgets.dart';

import 'package:karmashala_ui/icons.dart';

/// The one description of the settings screen: its groups, pages, the titled
/// sections on each page, and every option a search can land on. The rail,
/// search, page layout and deep links all read this, so none can drift.
/// See docs/settings-ia.md.
enum SettingsGroup {
  general('General'),
  workspace('Workspace'),
  agents('Agents'),
  connections('Connections'),
  advanced('Advanced');

  const SettingsGroup(this.label);

  final String label;

  List<SettingsSectionId> get pages => [
    for (final page in SettingsSectionId.values)
      if (page.group == this) page,
  ];
}

/// A page of the settings screen — one row in the rail. Declaration order is
/// rail order: common first, advanced last. Labels quoted as "Settings → …" in
/// refusals and tool descriptions (Agents, Environments, Tools, Permissions,
/// Diagnostics, Remote access, Terminal) keep those words.
enum SettingsSectionId {
  general(
    'General',
    AppIcons.power,
    SettingsGroup.general,
    'How Karmashala starts, the global hotkey, and optional features.',
  ),
  appearance(
    'Appearance',
    AppIcons.circleHalf,
    SettingsGroup.general,
    'Theme, text size and density for the whole app, and what the side '
        'panel’s rail shows.',
  ),
  editorFiles(
    'Editor & files',
    AppIcons.fileCode,
    SettingsGroup.general,
    'The in-app editor, file browsing, and the apps work is handed to.',
  ),
  terminal(
    'Terminal',
    AppIcons.terminal,
    SettingsGroup.workspace,
    'The shell new terminals open with, how they look, and which keys they '
        'keep.',
  ),
  projects(
    'Projects',
    AppIcons.folders,
    SettingsGroup.workspace,
    'What each checkout needs in a new worktree, and what it can build.',
  ),
  // Beside Projects: an emulator is where an app project runs. Orca files its
  // Mobile Emulator page under Workflows, its equivalent of this group.
  devices(
    'Devices',
    AppIcons.deviceMobile,
    SettingsGroup.workspace,
    'What Android emulators and iOS simulators start with, and what is '
        'switched off inside them.',
  ),
  snippets(
    'Snippets',
    AppIcons.bookBookmark,
    SettingsGroup.workspace,
    'Saved commands you can insert into any terminal.',
  ),
  environmentVariables(
    'Variables & secrets',
    AppIcons.clipboardText,
    SettingsGroup.workspace,
    'Environment variables every terminal Karmashala opens starts with.',
  ),
  agents(
    'Agents',
    AppIcons.robot,
    SettingsGroup.agents,
    'Which agent and model a new session starts with, and where each CLI '
        'lives.',
  ),
  accounts(
    'Accounts & usage',
    AppIcons.userCircle,
    SettingsGroup.agents,
    'Who each agent is signed in as, and how much of its limit is left.',
  ),
  permissions(
    'Permissions',
    AppIcons.handTap,
    SettingsGroup.agents,
    'What each agent may do without asking, and what each project lets it '
        'do in the browser.',
  ),
  // An automation is an agent, a prompt and a permission mode armed in
  // advance, so it follows the permissions it runs under.
  automations(
    'Automations',
    AppIcons.clockCounterClockwise,
    SettingsGroup.agents,
    'Agent runs armed to start on a schedule, with nobody watching.',
  ),
  tools(
    'Tools',
    AppIcons.code,
    SettingsGroup.agents,
    'The MCP bridge an agent reaches Karmashala through, what it can call, '
        'and the skills written into it.',
  ),
  environments(
    'Environments',
    AppIcons.terminalWindow,
    SettingsGroup.connections,
    'The machines work runs on — this computer, WSL, SSH hosts — and their '
        'tooling.',
  ),
  remote(
    'Remote access',
    AppIcons.wifiHigh,
    SettingsGroup.connections,
    'Pair a phone to follow and answer sessions from anywhere.',
  ),
  diagnostics(
    'Diagnostics',
    AppIcons.listMagnifyingGlass,
    SettingsGroup.advanced,
    'Logs, debug mode, and readings for a bug report.',
  );

  const SettingsSectionId(this.label, this.icon, this.group, this.description);

  final String label;
  final IconData icon;
  final SettingsGroup group;
  final String description;

  /// The sections on this page, in the order they are drawn.
  List<SettingsAnchor> get anchors => [
    for (final anchor in SettingsAnchor.values)
      if (anchor.page == this) anchor,
  ];

  /// The options on this page.
  List<SettingsEntry> get entries => [
    for (final entry in settingsEntries)
      if (entry.anchor.page == this) entry,
  ];

  /// Every word this page answers to: its sections' titles and keywords and
  /// its options' labels and keywords, lower-cased.
  List<String> get keywords => {
    for (final anchor in anchors) ...[
      anchor.title.toLowerCase(),
      ...anchor.keywords,
    ],
    for (final entry in entries) ...[
      entry.label.toLowerCase(),
      ...entry.keywords,
    ],
  }.toList();

  /// Whether the page stays listed while [query] is in the filter.
  bool matches(String query) {
    final q = normaliseSettingsQuery(query);
    if (q.isEmpty) return true;
    if (label.toLowerCase().contains(q)) return true;
    if (description.toLowerCase().contains(q)) return true;
    return keywords.any((k) => k.contains(q)) ||
        entries.any((e) => e.matches(q));
  }
}

/// A titled section on a page: where a deep link or a search hit scrolls to.
/// [heading] is the label the section draws, so a test can hold the two
/// together. Declaration order within a page is page order.
enum SettingsAnchor {
  startup(SettingsSectionId.general, 'Startup & window', [
    'startup',
    'start at login',
    'tray',
    'sleep',
    'system',
  ]),
  launcherHotkey(SettingsSectionId.general, 'Launcher hotkey', [
    'hotkey',
    'launcher',
    'shortcut',
  ]),
  notes(SettingsSectionId.general, 'Notes', [
    'note',
    'notes',
    'idea',
    'ideas',
    'save for later',
    'later',
  ]),
  themeText(SettingsSectionId.appearance, 'Theme & text', [
    'theme',
    'dark',
    'light',
    'text size',
    'zoom',
    'scale',
    'density',
    'compact',
  ]),
  // Also the rail's right-click menu and View › Side panel items.
  sidePanel(SettingsSectionId.appearance, 'Side panel', [
    'side panel',
    'rail',
    'activity bar',
    'sidebar',
    'panel items',
  ]),
  editor(SettingsSectionId.editorFiles, 'In-app editor', ['editor', 'wrap']),
  fileBrowsing(SettingsSectionId.editorFiles, 'File browsing', [
    'file picker',
    'browse',
    'hidden files',
  ]),
  externalTerminal(SettingsSectionId.editorFiles, 'External terminal', [
    'terminal app',
    'resume',
  ]),
  externalEditor(SettingsSectionId.editorFiles, 'External editor', [
    'editor',
    'vs code',
    'open in editor',
  ]),
  defaultTerminal(SettingsSectionId.terminal, 'Default terminal', [
    'shell',
    'profile',
  ]),
  terminalFont(SettingsSectionId.terminal, 'Font', ['font', 'size']),
  terminalTheme(SettingsSectionId.terminal, 'Terminal theme', [
    'theme',
    'colors',
    'colours',
  ]),
  terminalChords(SettingsSectionId.terminal, 'Terminal chords', [
    'chords',
    'keys',
  ]),
  terminalAdvanced(
    SettingsSectionId.terminal,
    'Shell integration & session host',
    ['integration', 'session host'],
  ),
  worktreeSetup(SettingsSectionId.projects, 'Worktree setup', [
    'worktree',
    'worktrees',
    'setup',
    'post create',
    'pub get',
    'copy',
    'gitignored',
    'dart_tool',
    'node_modules',
  ]),
  appProjects(SettingsSectionId.projects, 'App projects', [
    'app projects',
    'flutter',
    'react native',
    'build',
  ]),
  // Also shown from the device pane's Slimming buttons; one widget draws both.
  androidEmulators(SettingsSectionId.devices, 'Android emulators', [
    'android',
    'emulator',
    'emulators',
    'avd',
    'slimming',
    'gpu',
    'renderer',
  ]),
  iosSimulators(SettingsSectionId.devices, 'iOS simulators', [
    'ios',
    'simulator',
    'simulators',
    'iphone',
    'slimming',
  ]),
  snippets(SettingsSectionId.snippets, 'Command snippets', [
    'snippet',
    'snippets',
    'command',
    'commands',
    'saved command',
    'library',
  ]),
  variables(SettingsSectionId.environmentVariables, 'Environment variables', [
    'env',
    'env var',
    'environment variable',
    'secret',
    'secrets',
    'token',
    'api key',
    'credential',
  ]),
  automations(SettingsSectionId.automations, 'Automations', [
    'automation',
    'automations',
    'schedule',
    'scheduled',
    'cron',
    'nightly',
    'unattended',
    'afk',
    'project check',
    'checks',
    'verification',
  ]),
  defaultAgent(SettingsSectionId.agents, 'Default agent', ['default agent']),
  defaultModel(SettingsSectionId.agents, 'Default model', [
    'default model',
    'model',
    'opus',
    'sonnet',
  ]),
  detection(SettingsSectionId.agents, 'Detection', ['detect', 'scan']),
  executables(SettingsSectionId.agents, 'Executables', [
    'executable',
    'path',
    'cli',
  ]),
  claudeAccounts(SettingsSectionId.accounts, 'Claude accounts', [
    'claude',
    'accounts',
  ]),
  codexAccounts(SettingsSectionId.accounts, 'Codex accounts', [
    'codex',
    'accounts',
  ]),
  usage(SettingsSectionId.accounts, 'Usage & limits', ['usage', 'limits']),
  permissionModes(SettingsSectionId.permissions, 'Permission modes', [
    'ask',
    'bypass',
    'accept edits',
    'sessions',
  ]),
  // Quoted as kBrowserConsentLocation in the browser tools' refusals and
  // schemas. Was Tools › Browser; the enum name is kept so old links resolve.
  browser(SettingsSectionId.permissions, 'Browser', [
    'browser consent',
    'browser',
    'consent',
    'javascript',
  ]),
  mcpBridge(SettingsSectionId.tools, 'MCP bridge', ['mcp', 'bridge']),
  toolCatalogue(SettingsSectionId.tools, 'What an agent can call', [
    'agent tools',
    'tool list',
  ]),
  skills(SettingsSectionId.tools, 'Skills', ['skills']),
  executionEnvironments(
    SettingsSectionId.environments,
    'Execution environments',
    ['wsl', 'windows', 'discover', 'installations'],
  ),
  sshHosts(SettingsSectionId.environments, 'SSH hosts', [
    'ssh',
    'hosts',
    'remote build',
  ]),
  flutterSdk(SettingsSectionId.environments, 'Flutter SDK', [
    'flutter',
    'flutter sdk',
    'sdk',
    'dart',
  ]),
  buildTooling(SettingsSectionId.environments, 'Build tooling', [
    'toolchain',
    'build',
  ]),
  // SSH plumbing, not a place work runs; last on the page (SETTLED).
  knownHosts(SettingsSectionId.environments, 'Trusted host keys', [
    'known hosts',
    'keys',
  ]),
  remoteAccess(SettingsSectionId.remote, 'Remote access', [
    'companion',
    'phone',
    'pairing',
    'relay',
    'devices',
  ]),
  debugMode(SettingsSectionId.diagnostics, 'Debug mode', [
    'debug',
    'debug mode',
    'verbose',
  ]),
  logFile(SettingsSectionId.diagnostics, 'Log file', [
    'logs',
    'log file',
    'troubleshoot',
    'report',
  ]),
  scrollbackPersistence(
    SettingsSectionId.diagnostics,
    'Scrollback persistence',
    ['scrollback', 'autosave'],
  ),
  sessionWatching(SettingsSectionId.diagnostics, 'Session watching', [
    'watch',
    'status refresh',
  ]);

  const SettingsAnchor(this.page, this.title, this.keywords);

  final SettingsSectionId page;
  final String title;
  final List<String> keywords;

  /// The heading the section draws on its page.
  String get heading => title.toUpperCase();
}

/// One option a search can find: the label it has on screen, a line saying
/// what it does, and the other words a person might search for it by.
@immutable
class SettingsEntry {
  const SettingsEntry(
    this.label, {
    required this.anchor,
    required this.description,
    this.keywords = const [],
  });

  final String label;
  final SettingsAnchor anchor;
  final String description;
  final List<String> keywords;

  SettingsSectionId get page => anchor.page;

  /// [query] is already normalised by [normaliseSettingsQuery].
  bool matches(String query) {
    if (query.isEmpty) return false;
    return label.toLowerCase().contains(query) ||
        description.toLowerCase().contains(query) ||
        anchor.title.toLowerCase().contains(query) ||
        keywords.any((k) => k.contains(query));
  }
}

String normaliseSettingsQuery(String query) => query.trim().toLowerCase();

/// The options [query] finds, in rail order.
List<SettingsEntry> searchSettings(String query) {
  final q = normaliseSettingsQuery(query);
  if (q.isEmpty) return const [];
  return [
    for (final page in SettingsSectionId.values)
      for (final entry in page.entries)
        if (entry.matches(q)) entry,
  ];
}

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
    'Side panel items',
    anchor: SettingsAnchor.sidePanel,
    description: 'Which tools keep a glyph on the side panel’s rail.',
    keywords: ['hide', 'show', 'rail', 'activity bar', 'icons', 'glyphs'],
  ),
  SettingsEntry(
    'Wrap long lines in the editor',
    anchor: SettingsAnchor.editor,
    description: 'Soft-wrap instead of scrolling sideways.',
    keywords: ['word wrap', 'soft wrap', 'line numbers'],
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
    description: 'Use a Ghostty or Warp theme found on this machine.',
    keywords: ['theme', 'colors', 'ghostty', 'warp'],
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
    'Run local terminals in the session host',
    anchor: SettingsAnchor.terminalAdvanced,
    description: 'Shells that survive a crash or a restart of the app.',
    keywords: ['session host', 'karmashala_host', 'persistent'],
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
    'Load these in new terminals',
    anchor: SettingsAnchor.variables,
    description:
        'Environment variables and secrets every terminal starts '
        'with.',
    keywords: ['env', 'secret', 'token', 'api key', 'wslenv'],
  ),
  SettingsEntry(
    'Scheduled automations',
    anchor: SettingsAnchor.automations,
    description: 'Arm, pause and review agent runs on a schedule.',
    keywords: ['cron', 'nightly', 'schedule', 'project check'],
  ),
  SettingsEntry(
    'Default agent',
    anchor: SettingsAnchor.defaultAgent,
    description: 'Pre-selected when starting a session.',
    keywords: ['new session', 'pre-selected'],
  ),
  SettingsEntry(
    'Default model',
    anchor: SettingsAnchor.defaultModel,
    description: 'The model new sessions on each agent start on.',
    keywords: ['model', 'opus', 'sonnet', 'gpt'],
  ),
  SettingsEntry(
    'Detect agents',
    anchor: SettingsAnchor.detection,
    description: 'Search every environment for installed agent CLIs again.',
    keywords: ['detect', 'scan', 'install', 'claude', 'codex', 'antigravity'],
  ),
  SettingsEntry(
    'Executable path',
    anchor: SettingsAnchor.executables,
    description: 'Where each agent CLI lives, and whether it still opens.',
    keywords: ['path', 'executable', 'not found', 'repoint'],
  ),
  SettingsEntry(
    'Claude accounts',
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
    'Debug mode',
    anchor: SettingsAnchor.debugMode,
    description: 'Record fine detail and add a Logs panel.',
    keywords: ['debug', 'verbose', 'logs panel'],
  ),
  SettingsEntry(
    'Lines kept in memory',
    anchor: SettingsAnchor.debugMode,
    description: 'How much the Logs panel keeps.',
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
];

/// Where a deep link or a search hit lands: a page, and optionally a section
/// to scroll to.
class SettingsTarget {
  /// An anchor wins over [page], so a link written before its section moved
  /// (Tools › Browser) still lands on it.
  SettingsTarget(SettingsSectionId page, {this.anchor})
    : page = anchor?.page ?? page;

  SettingsTarget.anchor(SettingsAnchor this.anchor) : page = anchor.page;

  final SettingsSectionId page;
  final SettingsAnchor? anchor;
}
