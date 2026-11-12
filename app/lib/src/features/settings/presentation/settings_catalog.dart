import 'package:flutter/widgets.dart';
import 'package:karmashala_core/util.dart';

import 'package:karmashala_ui/icons.dart';

import '../../../core/capabilities/capabilities.dart';

part 'settings_catalog/anchors.dart';
part 'settings_catalog/entries.dart';

/// The one description of the settings screen: its groups, pages, the titled
/// sections on each page, and every option a search can land on. The page
/// list, search, page layout and deep links all read this, so none can drift.
/// Grouped by what a person is doing: the app itself, how sessions behave,
/// the agents that run them, the work, and what the app connects to.
enum SettingsGroup {
  general('App'),
  sessions('Sessions'),
  agents('Agents'),
  workspace('Workspace'),
  connections('Connections'),
  advanced('Advanced');

  const SettingsGroup(this.label);

  final String label;

  List<SettingsSectionId> get pages => [
    for (final page in SettingsSectionId.values)
      if (page.group == this) page,
  ];
}

/// A page of the settings screen — one row in its page list. Declaration
/// order is list order: common first, advanced last. Page labels are quoted
/// as "Settings → …" in refusals, tool descriptions and the MCP instructions;
/// a rename moves those quotes in the same change. Enum names outlive their
/// labels (Environments is now Machines), so a link written against the old
/// name still lands.
enum SettingsSectionId {
  general(
    'General',
    AppIcons.power,
    SettingsGroup.general,
    'How Karmashala starts and closes, the global hotkey, and notes.',
  ),
  appearance(
    'Appearance',
    AppIcons.circleHalf,
    SettingsGroup.general,
    'Theme, accent, text size, density, the sidebar and the context panel.',
  ),
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
  keyboard(
    'Keyboard',
    AppIcons.keyboard,
    SettingsGroup.general,
    'Every shortcut in force, the keymap that moves them, and which keys '
        'terminals keep.',
  ),
  // How a session starts and how many run: gathered from General and Agents
  // and accounts, so one page answers "what happens when I start one".
  sessions(
    'Sessions',
    AppIcons.chat,
    SettingsGroup.sessions,
    'How a session opens, the agent it starts on, how many run at once, and '
        'what a session hears of one it starts.',
    ['session', 'new session', 'general'],
  ),
  // What a session may do without asking. Was half of Tools and reach, plus
  // the New sessions switches from Agents and accounts.
  permissions(
    'Permissions',
    AppIcons.shield,
    SettingsGroup.sessions,
    'What agents may do without asking, whether new sessions may operate '
        'Karmashala, folder trust, and browser consent.',
    ['permissions', 'tools and reach', 'reach', 'trust'],
  ),
  // The enum name is kept so old links resolve; automations have their own
  // tab, and this page keeps one row that opens it.
  automations(
    'Checkpoints',
    AppIcons.clockCounterClockwise,
    SettingsGroup.sessions,
    'Snapshots of every agent turn; automations and resumes have their own '
        'tab.',
    ['automations', 'checkpoints', 'checkpoints and automations'],
  ),
  // One card per agent: its machines, executables, accounts and behaviour,
  // then what spans them.
  agents(
    'Agents and accounts',
    AppIcons.robot,
    SettingsGroup.agents,
    'Where each agent is installed, who it is signed in as, how much limit '
        'is left, and how agents are updated and found.',
    ['agents', 'accounts & usage', 'accounts', 'usage'],
  ),
  // Was the other half of Tools and reach.
  tools(
    'MCP and skills',
    AppIcons.code,
    SettingsGroup.agents,
    'The MCP bridge, the tools an agent can call, and installed skills.',
    ['tools', 'tools and reach', 'mcp', 'skills'],
  ),
  bot(
    'Bot',
    AppIcons.chatCircleDots,
    SettingsGroup.agents,
    'The agent the Karmashala bot runs on.',
    ['bot', 'assistant'],
  ),
  projects(
    'Projects',
    AppIcons.folders,
    SettingsGroup.workspace,
    'What each checkout needs in a new worktree, and what can be built.',
    ['projects', 'projects and files'],
  ),
  // Was the second half of Projects and files.
  editorFiles(
    'Editor and files',
    AppIcons.fileCode,
    SettingsGroup.workspace,
    'The in-app editor, file browsing, and the apps work is handed to.',
    ['editor & files', 'editor', 'files', 'projects and files'],
  ),
  // Everything a terminal is: gathered from Appearance (colours), Snippets
  // and Diagnostics (scrollback).
  terminal(
    'Terminal',
    AppIcons.terminal,
    SettingsGroup.workspace,
    'Default shell, font, colours, scrollback, and saved commands.',
    ['snippets'],
  ),
  // An emulator is where an app project runs.
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
  // of each machine.
  server(
    'Server',
    AppIcons.stack,
    SettingsGroup.connections,
    'This machine\'s Karmashala server: whether it runs, its log, and what '
        'it keeps on disk.',
    ['server', 'host', 'session host', 'karmashala host', 'karmashala_host'],
  ),
  // Was Remote and pairing, and Remote access before that.
  remote(
    'Phone pairing',
    AppIcons.wifiHigh,
    SettingsGroup.connections,
    'Pair a phone to follow and answer sessions from anywhere.',
    ['remote access', 'remote', 'remote and pairing', 'pairing'],
  ),
  // Was Source control: GitHub is all it holds.
  sourceControl(
    'GitHub',
    AppIcons.gitBranch,
    SettingsGroup.connections,
    'GitHub access: a token, or which gh account each host uses.',
    ['git', 'github', 'source control'],
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
  // With the other credentials: agents' logins read these as terminals do.
  environmentVariables(
    'Variables and secrets',
    AppIcons.clipboardText,
    SettingsGroup.connections,
    'Variables every new terminal starts with, and secrets agents sign in '
        'with.',
    ['variables & secrets'],
  ),
  // Was Data.
  data(
    'Backup',
    AppIcons.floppyDisk,
    SettingsGroup.advanced,
    'Back up Karmashala\'s sessions, settings and evidence, on a schedule '
        'or now, and restore a backup.',
    ['backup', 'back up', 'restore', 'export', 'migrate', 'data'],
  ),
  diagnostics(
    'Diagnostics',
    AppIcons.listMagnifyingGlass,
    SettingsGroup.advanced,
    'Logs, debug mode, and readings for a bug report.',
  ),
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

  /// Pages merged into another, kept as names so a link or a test written
  /// against them lands on the page that holds their sections now. Not in
  /// [values]: the page list never shows them.
  static const accounts = agents;
  static const snippets = terminal;

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
