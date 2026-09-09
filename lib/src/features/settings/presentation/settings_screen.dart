import 'package:flutter/material.dart';

import '../../automations/presentation/automations_page.dart';
import '../../../app/shell/app_shell.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../env_secrets/presentation/env_secrets_page.dart';
import '../../environments/presentation/environments_section.dart';
import '../../app_projects/presentation/project_kinds_section.dart';
import '../../flutter_apps/presentation/flutter_sdk_section.dart';
import '../../git/presentation/worktree_setup_page.dart';
import '../../notes/presentation/notes_settings_section.dart';
import '../../remote/presentation/remote_access_section.dart';
import '../../snippets/presentation/snippets_settings_page.dart';
import '../../ssh/presentation/known_hosts_section.dart';
import '../../ssh/presentation/ssh_hosts_section.dart';
import 'agents_pages.dart';
import 'diagnostics_page.dart';
import 'general_pages.dart';
import 'permissions_page.dart';
import 'settings_nav.dart';
import 'terminal_pages.dart';
import 'tools_page.dart';

/// Settings, as a master-detail page: a compact section nav on the left (with
/// a filter box and arrow-key navigation), the selected section's content on
/// the right, constrained to a readable width instead of one skinny column
/// lost in a wide window.
///
/// At compact widths (a small window, the phone form factor) the same nav
/// becomes a drill-down list: pick a section, get its page, back out with the
/// app bar. The selected section lives on this state, so resizing across the
/// breakpoint keeps your place.
///
/// **Mounted, never pushed.** The desktop draws it as a workbench tab
/// ([SettingsTabView]); the window-matrix tests mount it directly. It used to
/// carry a `show` that pushed it as a full-screen `MaterialPageRoute`, which
/// covered the menu bar, the tab strip and the very panes half of these
/// settings are about — the backlog item this page's shape now answers.
/// Nothing needed that route kept: there is no first-run flow, and the phone
/// has its own `CompanionSettingsScreen`.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({this.initialSection, this.onSectionChanged, super.key});

  /// The section to land on — how menu items and quick open deep-link
  /// ("agents" from an agent entry, and so on). Changing it moves the page,
  /// so a deep link into a Settings tab that is already open lands on its
  /// section rather than leaving the user where they were.
  final SettingsSectionId? initialSection;

  /// Told which section the user moved to, and told `null` when a compact
  /// window backs out to the list. How the workbench tab keeps the page
  /// outside a `State` it drops every time another tab is on screen — see
  /// [SettingsTabView].
  final ValueChanged<SettingsSectionId?>? onSectionChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsSectionId _selected =
      widget.initialSection ?? SettingsSectionId.appearance;

  /// Whether the compact layout is showing a section rather than the list.
  /// Deep links open straight into their section.
  late bool _openOnCompact = widget.initialSection != null;

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection == oldWidget.initialSection) return;
    // A deep link arriving at a screen that is already up. Null is the compact
    // list rather than a section, which is what backing out writes.
    _selected = widget.initialSection ?? _selected;
    _openOnCompact = widget.initialSection != null;
  }

  void _select(SettingsSectionId section) {
    setState(() {
      _selected = section;
      _openOnCompact = true;
    });
    widget.onSectionChanged?.call(section);
  }

  void _backToList() {
    setState(() => _openOnCompact = false);
    widget.onSectionChanged?.call(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = ShellWidth.of(constraints.maxWidth).isCompact;
        final showingSection = !compact || _openOnCompact;
        return Scaffold(
          appBar: AppBar(
            // A page header, not a chrome row: `Chrome.titleBar` is the
            // shell's 30px strip and a back button plus a title does not sit
            // in it.
            toolbarHeight: 44,
            // **The only way back is a step inside the page.** There used to
            // be a second `BackButton` here that popped the route this page
            // was pushed as; the page is a workbench tab now, so there is no
            // route to pop and an implied one would pop the app's own. The
            // way *out* of Settings is the way out of any tab — close it, or
            // pick another.
            automaticallyImplyLeading: false,
            leading: compact && _openOnCompact
                ? BackButton(onPressed: _backToList)
                : null,
            title: Row(
              children: [
                Icon(AppIcons.gearSix, color: theme.colorScheme.tertiary),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Text(
                    compact && showingSection
                        ? 'Settings · ${_selected.label}'
                        : 'Settings',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Each scrolling column is its own traversal group. Reading order
          // alone sorts on *global* position, which broke Tab twice: side by
          // side it treated the rail and the content as one flow and bounced
          // between them, and once the content had scrolled its negative
          // coordinates sorted it above the app bar, so the ring never came
          // back to the back button.
          body: compact
              ? FocusTraversalGroup(
                  child: showingSection
                      ? _SectionContent(section: _selected)
                      : SettingsNav(selected: null, onSelect: _select),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 208,
                      child: FocusTraversalGroup(
                        child: SettingsNav(
                          selected: _selected,
                          onSelect: _select,
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: FocusTraversalGroup(
                        child: _SectionContent(section: _selected),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// The selected section's page, scrolled, and held to a readable width — the
/// space a wide window adds goes to margin, not to 900px-long switch rows.
class _SectionContent extends StatelessWidget {
  const _SectionContent({required this.section});

  final SettingsSectionId section;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      // A fresh scroll position per section, not one shared offset that
      // leaves the next section opened halfway down.
      key: PageStorageKey('settings-${section.name}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xl,
        vertical: Insets.lg,
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _pageFor(section),
        ),
      ),
    );
  }

  Widget _pageFor(SettingsSectionId section) => switch (section) {
    SettingsSectionId.appearance => const AppearancePage(),
    SettingsSectionId.system => const SystemPage(),
    SettingsSectionId.terminal => const TerminalPage(),
    SettingsSectionId.snippets => const SnippetsSettingsPage(),
    SettingsSectionId.tools => const ToolsPage(),
    SettingsSectionId.agents => const AgentsPage(),
    SettingsSectionId.permissions => const PermissionsPage(),
    // Agents are listed under the environment they are installed in: the same
    // CLI on the Windows host and on a build box are two independent
    // installations.
    SettingsSectionId.automations => const AutomationsPage(),
    SettingsSectionId.worktrees => const WorktreeSetupPage(),
    // Two blocks, because they answer two questions about the same list: what
    // was *found* in each environment, and — under it — the one thing a person
    // may have to say themselves.
    SettingsSectionId.environments => const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EnvironmentsSection(),
        FlutterSdkSection(),
        ProjectKindsSection(),
      ],
    ),
    SettingsSectionId.environmentVariables => const EnvSecretsPage(),
    SettingsSectionId.ssh => const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [SshHostsSection(), KnownHostsSection()],
    ),
    SettingsSectionId.remote => const RemoteAccessSection(),
    SettingsSectionId.notes => const NotesSettingsSection(),
    SettingsSectionId.diagnostics => const DiagnosticsPage(),
  };
}
