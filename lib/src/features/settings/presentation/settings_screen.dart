import 'package:flutter/material.dart';

import '../../../app/shell/app_shell.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../environments/presentation/environments_section.dart';
import '../../remote/presentation/remote_access_section.dart';
import '../../ssh/presentation/known_hosts_section.dart';
import '../../ssh/presentation/ssh_hosts_section.dart';
import 'agents_pages.dart';
import 'general_pages.dart';
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
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({this.initialSection, super.key});

  /// The section to land on — how menu items and quick open deep-link
  /// ("agents" from an agent entry, and so on).
  final SettingsSectionId? initialSection;

  static Future<void> show(
    BuildContext context, {
    SettingsSectionId? section,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => SettingsScreen(initialSection: section)),
  );

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsSectionId _selected =
      widget.initialSection ?? SettingsSectionId.appearance;

  /// Whether the compact layout is showing a section rather than the list.
  /// Deep links open straight into their section.
  late bool _openOnCompact = widget.initialSection != null;

  void _select(SettingsSectionId section) => setState(() {
    _selected = section;
    _openOnCompact = true;
  });

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
            leading: compact && _openOnCompact
                ? BackButton(
                    onPressed: () => setState(() => _openOnCompact = false),
                  )
                : const BackButton(),
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
    SettingsSectionId.tools => const ToolsPage(),
    SettingsSectionId.agents => const AgentsPage(),
    SettingsSectionId.permissions => const PermissionsPage(),
    // Agents are listed under the environment they are installed in: the same
    // CLI on the Windows host and on a build box are two independent
    // installations.
    SettingsSectionId.environments => const EnvironmentsSection(),
    SettingsSectionId.ssh => const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [SshHostsSection(), KnownHostsSection()],
    ),
    SettingsSectionId.remote => const RemoteAccessSection(),
  };
}
