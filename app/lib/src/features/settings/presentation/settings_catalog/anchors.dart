part of '../settings_catalog.dart';

// The titled sections on each settings page.

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
  dataBackup(SettingsSectionId.data, 'Back up', [
    'backup',
    'back up',
    'schedule',
    'daily',
    'weekly',
    'retention',
    'archive',
  ]),
  dataRestore(SettingsSectionId.data, 'Restore', [
    'restore',
    'recover',
    'recovery',
    'migrate',
    'new machine',
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
    // Made and restored by this machine's server, from its own disk.
    dataBackup || dataRestore => caps.hostsServer && caps.serverSettings,
    _ => true,
  };
}
