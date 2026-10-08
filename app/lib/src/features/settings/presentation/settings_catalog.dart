import 'package:flutter/widgets.dart';
import 'package:karmashala_core/util.dart';

import 'package:karmashala_ui/icons.dart';

import '../../../core/capabilities/capabilities.dart';

/// The one description of the settings screen: its groups, pages, the titled
/// sections on each page, and every option a search can land on. The page
/// list, search, page layout and deep links all read this, so none can drift.
enum SettingsGroup {
  general('App'),
  agents('Agents'),
  workspace('Work'),
  connections('Machines'),
  advanced('Advanced');

  const SettingsGroup(this.label);

  final String label;

  List<SettingsSectionId> get pages => [
    for (final page in SettingsSectionId.values)
      if (page.group == this) page,
  ];
}

/// A page of the settings screen — one row in its page list. Declaration
/// order is list order: common first, advanced last, the groups and pages of
/// UI overhaul spec §6. Page labels are quoted as "Settings → …" in refusals,
/// tool descriptions and the MCP instructions; a rename moves those quotes in
/// the same change. Enum names outlive their labels (Environments is now
/// Machines), so a link written against the old name still lands.
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
    'Theme, accent, text size, density, terminal colours, the sidebar and '
        'the context panel.',
  ),
  // The switches were only ever in the tray menu; a page is where somebody
  // looks for them. Drawn by the screen, not an anchor (see settings_screen).
  notifications(
    'Notifications',
    AppIcons.tray,
    SettingsGroup.general,
    'When a desktop notification is sent, and for what.',
    [
      'notification',
      'notifications',
      'toast',
      'alert',
      'desktop notification',
      'finished',
      'needs you',
      'focus',
      'tray',
    ],
  ),
  // Was General › Keyboard.
  keyboard(
    'Keyboard',
    AppIcons.keyboard,
    SettingsGroup.general,
    'Every shortcut in force, and the keymap that moves them.',
  ),
  // Was Agents plus Accounts & usage: an agent's installs, the accounts they
  // are signed in to, and how it behaves, on one page (spec §6).
  agents(
    'Agents and accounts',
    AppIcons.robot,
    SettingsGroup.agents,
    'Which agent new sessions use, where each is installed, who it is signed '
        'in as, and how much limit is left.',
    ['agents', 'accounts & usage', 'accounts', 'usage'],
  ),
  // Was Tools plus Permissions: what an agent can call, and how far it may
  // go without asking.
  tools(
    'Tools and reach',
    AppIcons.code,
    SettingsGroup.agents,
    'What agents may do without asking, the MCP bridge, its tools, and '
        'installed skills.',
    ['tools', 'permissions'],
  ),
  // An automation is an agent, a prompt and a permission mode armed in
  // advance, so it follows the permissions it runs under. Checkpoints joined
  // it from the Agents page: both are what happens to work nobody watches.
  automations(
    'Checkpoints and automations',
    AppIcons.clockCounterClockwise,
    SettingsGroup.agents,
    'Snapshots of every agent turn; automations and resumes have their own '
        'tab.',
    ['automations', 'checkpoints'],
  ),
  snippets(
    'Snippets',
    AppIcons.bookBookmark,
    SettingsGroup.agents,
    'Saved commands you can insert into any terminal.',
  ),
  terminal(
    'Terminal',
    AppIcons.terminal,
    SettingsGroup.workspace,
    'Default shell, look, and which keys terminals keep.',
  ),
  // Was Projects plus Editor & files.
  projects(
    'Projects and files',
    AppIcons.folders,
    SettingsGroup.workspace,
    'What each checkout needs in a new worktree and can build, the in-app '
        'editor, file browsing, and the apps work is handed to.',
    ['projects', 'editor & files', 'editor'],
  ),
  // Beside Projects: an emulator is where an app project runs. Orca files its
  // Mobile Emulator page under Workflows, its equivalent of this group.
  devices(
    'Devices',
    AppIcons.deviceMobile,
    SettingsGroup.workspace,
    'How Android emulators and iOS simulators start.',
  ),
  // Was Environments. The enum name is kept so old links resolve.
  environments(
    'Machines',
    AppIcons.terminalWindow,
    SettingsGroup.connections,
    'The server this window uses, this computer, WSL and SSH hosts, and '
        'their tooling.',
    ['environments', 'environment'],
  ),
  // This machine's server; other machines' stay on Machines beside the rest
  // of each machine. Was Terminal › Shell integration & session host.
  server(
    'Server',
    AppIcons.stack,
    SettingsGroup.connections,
    'This machine\'s Karmashala server: whether it runs, its log, and what '
        'it keeps on disk.',
    ['server', 'host', 'session host', 'karmashala host', 'karmashala_host'],
  ),
  // Was Remote access.
  remote(
    'Remote and pairing',
    AppIcons.wifiHigh,
    SettingsGroup.connections,
    'Pair a phone to follow and answer sessions from anywhere.',
    ['remote access', 'remote'],
  ),
  sourceControl(
    'Source control',
    AppIcons.gitBranch,
    SettingsGroup.connections,
    'GitHub access: a token, or which gh account each host uses.',
    ['git', 'github'],
  ),
  environmentVariables(
    'Variables and secrets',
    AppIcons.clipboardText,
    SettingsGroup.connections,
    'Variables every new terminal starts with.',
    ['variables & secrets'],
  ),
  // The credentials the Stores tab reads with; the tab itself is a workbench
  // tab, as Usage is.
  stores(
    'Stores',
    AppIcons.package,
    SettingsGroup.connections,
    'The App Store Connect key and the Google Play service account the '
        'Stores tab reads with.',
    ['app store', 'google play', 'app store connect', 'play console'],
  ),
  diagnostics(
    'Diagnostics',
    AppIcons.listMagnifyingGlass,
    SettingsGroup.advanced,
    'Logs, debug mode, and readings for a bug report.',
  ),
  // The About dialog's facts, where Settings users look for them. Drawn by the
  // screen, not an anchor (see settings_screen).
  about(
    'About',
    AppIcons.info,
    SettingsGroup.advanced,
    'Which build this is, where it comes from, and its licences.',
    [
      'about',
      'version',
      'build',
      'licence',
      'licences',
      'license',
      'licenses',
      'open source',
      'bug report',
    ],
  );

  /// Pages merged into another by spec §6's regrouping, kept as names so a
  /// link or a test written against them lands on the page that holds their
  /// sections now. Not in [values]: the page list never shows them.
  static const accounts = agents;
  static const permissions = tools;
  static const editorFiles = projects;

  const SettingsSectionId(
    this.label,
    this.icon,
    this.group,
    this.description, [
    this.aliases = const [],
  ]);

  final String label;
  final IconData icon;
  final SettingsGroup group;
  final String description;

  /// Other words the page answers to, lower-cased: the names it had before a
  /// rename or a merge, so somebody who learned "Permissions" still finds it,
  /// and the words for a page drawn without anchors.
  final List<String> aliases;

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

  /// Whether this client lists the page: one of its sections is shown.
  bool shownWith(Capabilities caps) => anchors.any((a) => a.shownWith(caps));

  /// Every word this page answers to: its [aliases], its sections' titles and
  /// keywords and its options' labels and keywords, lower-cased.
  List<String> get keywords => _keywords(null);

  /// [keywords], leaving out the sections [caps] hides.
  List<String> _keywords(Capabilities? caps) => {
    ...aliases,
    for (final anchor in anchors)
      if (caps == null || anchor.shownWith(caps)) ...[
        anchor.title.toLowerCase(),
        ...anchor.keywords,
      ],
    for (final entry in entries)
      if (caps == null || entry.anchor.shownWith(caps)) ...[
        entry.label.toLowerCase(),
        ...entry.keywords,
      ],
  }.toList();

  /// Whether the page stays listed while [query] is in the filter. With
  /// [caps], a page or section this client hides never matches.
  bool matches(String query, {Capabilities? caps}) {
    if (caps != null && !shownWith(caps)) return false;
    final q = normaliseSettingsQuery(query);
    if (q.isEmpty) return true;
    return matchesSearchAny(q, [label, description, ..._keywords(caps)]) ||
        entries.any(
          (e) => (caps == null || e.anchor.shownWith(caps)) && e.matches(q),
        );
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
    'front',
    'background',
    'focus',
  ]),
  sessionView(SettingsSectionId.general, 'Session view', [
    'chat',
    'chat view',
    'terminal',
    'open',
    'session',
  ]),
  launcherHotkey(SettingsSectionId.general, 'Launcher hotkey', [
    'hotkey',
    'launcher',
    'shortcut',
  ]),
  keyboard(SettingsSectionId.keyboard, 'Keyboard', [
    'keyboard',
    'shortcuts',
    'keymap',
    'keybindings',
    'bindings',
    'keys',
  ]),
  // Anchors of their own, so search finds them and a link can land on them.
  notifications(SettingsSectionId.notifications, 'Notifications', [
    'notifications',
    'alerts',
    'toast',
    'sound',
    'badge',
    'tray',
  ]),
  about(SettingsSectionId.about, 'About', [
    'about',
    'version',
    'build',
    'licences',
    'licenses',
    'repository',
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
  // Moved from Terminal to Appearance with the built-in schemes; the enum name
  // is kept so a link written against it still lands, and Terminal › Font
  // keeps a row pointing here.
  terminalTheme(SettingsSectionId.appearance, 'Terminal colours', [
    'terminal',
    'colour',
    'colours',
    'color',
    'colors',
    'scheme',
    'theme',
    'palette',
    'ansi',
    'ghostty',
    'warp',
  ]),
  // Also View › Side panel items. The enum name is kept so old links resolve;
  // the rail and Explorer it was named for are gone, but people still search
  // by those words.
  sidePanel(SettingsSectionId.appearance, 'Sidebar & context panel', [
    'context panel',
    'more menu',
    'side panel',
    'sidebar',
    'panel items',
    'projects',
    'project path',
    'rail',
    'activity bar',
    'explorer',
  ]),
  defaultTerminal(SettingsSectionId.terminal, 'Default terminal', [
    'shell',
    'profile',
  ]),
  terminalFont(SettingsSectionId.terminal, 'Font', ['font', 'size']),
  terminalChords(SettingsSectionId.terminal, 'Terminal chords', [
    'chords',
    'keys',
  ]),
  // The enum name is kept so old links resolve; its session host half moved
  // to Server.
  terminalAdvanced(SettingsSectionId.terminal, 'Shell integration', [
    'integration',
  ]),
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
  editor(SettingsSectionId.projects, 'In-app editor', [
    'editor',
    'wrap',
    'auto save',
    'autosave',
  ]),
  fileBrowsing(SettingsSectionId.projects, 'File browsing', [
    'file picker',
    'browse',
    'hidden files',
  ]),
  externalTerminal(SettingsSectionId.projects, 'External terminal', [
    'terminal app',
    'resume',
  ]),
  externalEditor(SettingsSectionId.projects, 'External editor', [
    'editor',
    'vs code',
    'open in editor',
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
  github(SettingsSectionId.sourceControl, 'GitHub', [
    'github',
    'gh',
    'token',
    'personal access token',
    'enterprise',
    'pull request',
    'account',
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
  // Checkpoints first: every turn is snapshotted, whether or not an
  // automation ever runs (was Agents › Checkpoints).
  checkpoints(SettingsSectionId.automations, 'Checkpoints', [
    'checkpoint',
    'checkpoints',
    'rewind',
    'undo',
    'rollback',
    'snapshot',
  ]),
  automations(SettingsSectionId.automations, 'Automations', [
    'automation',
    'automations',
    'webhook',
    'webhooks',
    'schedule',
    'scheduled',
    'cron',
    'run now',
    'runs',
    'nightly',
    'unattended',
    'event',
    'trigger',
    'when a session finishes',
    'afk',
    'project check',
    'checks',
    'verification',
    'resume',
    'resumes',
    'usage limit',
    'rate limit',
    'reset',
    'continue',
  ]),
  // Agents and accounts, in the order the page draws them: Defaults (the
  // header strip), then the terminal agents as cards — Claude's and Codex's
  // anchors and the default model open the card they belong to, executables
  // lands on the group — then usage, updates and detection at the end.
  // Titles are the headings the page draws, so a search hit names the
  // section it opens.
  defaultAgent(SettingsSectionId.agents, 'Defaults', [
    'default agent',
    'defaults',
    'new session',
  ]),
  claudeAccounts(SettingsSectionId.agents, 'Claude Code · accounts', [
    'claude',
    'accounts',
    'machines',
    'sign in',
    'capture',
    'switch account',
  ]),
  codexAccounts(SettingsSectionId.agents, 'Codex CLI · accounts', [
    'codex',
    'accounts',
    'machines',
    'sign in',
    'capture',
  ]),
  defaultModel(SettingsSectionId.agents, 'Claude Code · behaviour', [
    'default model',
    'model',
    'opus',
    'sonnet',
    'behaviour',
    'permission mode',
    'sandbox',
  ]),
  usage(SettingsSectionId.agents, 'Usage & limits', ['usage', 'limits']),
  agentUpdates(SettingsSectionId.agents, 'Agent updates', [
    'update',
    'updates',
    'self-update',
    'auto-update',
    'autoupdate',
    'upgrade',
    'antivirus',
    'bitdefender',
  ]),
  executables(SettingsSectionId.agents, 'Executables', [
    'executable',
    'path',
    'cli',
  ]),
  detection(SettingsSectionId.agents, 'Find agents', [
    'detect',
    'detection',
    'scan',
    'rescan',
  ]),
  permissionModes(SettingsSectionId.tools, 'Permission modes', [
    'ask',
    'bypass',
    'accept edits',
    'sessions',
  ]),
  // Quoted as kBrowserConsentLocation in the browser tools' refusals and
  // schemas. Was Tools › Browser, then Permissions › Browser; now Tools and
  // reach › Browser. The enum name is kept so old links resolve.
  browser(SettingsSectionId.tools, 'Browser', [
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
  // The server this window uses, first on the Machines page it is named
  // for (was Remote access › Machines).
  machines(SettingsSectionId.environments, 'Machines', [
    'machine',
    'machines',
    'server',
    'remote server',
    'switch machine',
  ]),
  executionEnvironments(
    SettingsSectionId.environments,
    'Execution environments',
    ['wsl', 'windows', 'discover', 'installations'],
  ),
  sshHosts(SettingsSectionId.environments, 'SSH hosts', [
    'ssh',
    'hosts',
    'remote build',
    'pair phone',
    'qr',
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
  // SSH plumbing, not a place work runs; last on the page.
  knownHosts(SettingsSectionId.environments, 'Trusted host keys', [
    'known hosts',
    'keys',
  ]),
  serverStatus(SettingsSectionId.server, 'Status and controls', [
    'status',
    'restart',
    'stop',
    'start',
    'version',
    'uptime',
    'data folder',
    'socket',
    'session host',
  ]),
  serverLog(SettingsSectionId.server, 'Log', [
    'server log',
    'server.log',
    'logs',
    'log file',
  ]),
  serverStorage(SettingsSectionId.server, 'Storage', [
    'storage',
    'disk',
    'database',
    'size',
    'tool images',
    'cache',
    'clean up',
    'old sessions',
  ]),
  remoteAccess(SettingsSectionId.remote, 'Remote access', [
    'companion',
    'phone',
    'pairing',
    'relay',
    'ssh relay',
    'devices',
  ]),
  storeCredentials(SettingsSectionId.stores, 'Store credentials', [
    'stores',
    'app store',
    'google play',
    'app store connect',
    'play console',
    'credential',
    'api key',
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
  ]),
  memoryFootprint(SettingsSectionId.diagnostics, 'Memory footprint', [
    'memory',
    'ram',
    'leak',
    'resident',
  ]);

  const SettingsAnchor(this.page, this.title, this.keywords);

  final SettingsSectionId page;
  final String title;
  final List<String> keywords;

  /// The heading the section draws on its page.
  String get heading => title.toUpperCase();

  /// Whether this client shows the section (spec §3.2, rule 2): one that needs
  /// this machine is hidden, not shown broken.
  bool shownWith(Capabilities caps) => switch (this) {
    startup || launcherHotkey => caps.systemIntegration,
    keyboard => caps.keyboardSettings,
    notifications => caps.notifiesHere,
    androidEmulators || iosSimulators => caps.devicesArea,
    // The server-side half: its device list is refused without admin anyway.
    remoteAccess => caps.pairsHere || caps.serverAdmin,
    // This machine's server log; a phone hosts no server.
    serverLog => caps.hostsServer,
    // Read from and cleared at this machine's server, by this machine's app.
    serverStorage => caps.hostsServer && caps.serverSettings,
    _ => true,
  };
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
    return matchesSearchAny(query, [
      label,
      description,
      anchor.title,
      ...keywords,
    ]);
  }
}

String normaliseSettingsQuery(String query) => query.trim();

/// The options [query] finds, in page-list order; with [caps], none in a
/// section this client hides.
List<SettingsEntry> searchSettings(String query, {Capabilities? caps}) {
  final q = normaliseSettingsQuery(query);
  if (q.isEmpty) return const [];
  return [
    for (final page in SettingsSectionId.values)
      for (final entry in page.entries)
        if ((caps == null || entry.anchor.shownWith(caps)) && entry.matches(q))
          entry,
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
    'Open agent sessions in chat view',
    anchor: SettingsAnchor.sessionView,
    description: 'Terminal sessions show their chat first.',
    keywords: ['chat', 'terminal', 'phone', 'default'],
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
