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

/// Settings as a master-detail page, drilling down to one section at compact
/// widths. Mounted as a workbench tab ([SettingsTabView]), never pushed: a
/// route would cover the menu bar, the tab strip and the panes it configures.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({this.initialSection, this.onSectionChanged, super.key});

  /// The section to land on — how menu items and quick open deep-link. Changing
  /// it moves a Settings tab that is already open onto that section.
  final SettingsSectionId? initialSection;

  /// Told which section the user moved to, and `null` when a compact window
  /// backs out — how [SettingsTabView] keeps the page outside a dropped `State`.
  final ValueChanged<SettingsSectionId?>? onSectionChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsSectionId _selected =
      widget.initialSection ?? SettingsSectionId.appearance;

  /// Whether the compact layout shows a section; a deep link opens into one.
  late bool _openOnCompact = widget.initialSection != null;

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection == oldWidget.initialSection) return;
    // A deep link at a screen already up; null is the compact list.
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
            // A page header, not a chrome row: `Chrome.titleBar` is 30px.
            toolbarHeight: 44,
            // A workbench tab: an implied leading button would pop the
            // app's own route.
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
          // Each scrolling column is its own traversal group: reading order
          // sorts on global position, so scrolled content outranks the app bar.
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

/// The selected section's page, held to a readable width — a wide window adds
/// margin, not 900px-long switch rows.
class _SectionContent extends StatelessWidget {
  const _SectionContent({required this.section});

  final SettingsSectionId section;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      // A fresh scroll position per section, not one shared offset.
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
    // Agents list under their environment: one CLI on two hosts is two.
    SettingsSectionId.automations => const AutomationsPage(),
    SettingsSectionId.worktrees => const WorktreeSetupPage(),
    // Two blocks: what was found, and what a person may have to say.
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
