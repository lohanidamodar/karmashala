import 'package:flutter/widgets.dart';
import 'package:karmashala_core/util.dart';

import 'package:karmashala_ui/icons.dart';

import '../../../core/capabilities/capabilities.dart';

part 'settings_catalog/anchors.dart';
part 'settings_catalog/entries.dart';

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
  data(
    'Data',
    AppIcons.floppyDisk,
    SettingsGroup.advanced,
    'Back up Karmashala\'s sessions, settings and evidence, on a schedule '
        'or now, and restore a backup.',
    ['backup', 'back up', 'restore', 'export', 'migrate'],
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
