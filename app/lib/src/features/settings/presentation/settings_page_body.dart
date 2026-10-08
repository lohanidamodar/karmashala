import 'about_page.dart';
import 'notifications_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';

import '../../app_projects/presentation/project_kinds_section.dart';
import '../../automations/presentation/automations_settings_link.dart';
import '../../automations/presentation/automations_tab_state.dart';
import '../../checkpoints/presentation/checkpoint_settings_section.dart';
import '../../env_secrets/presentation/env_secrets_page.dart';
import '../../github_access/presentation/github_access_page.dart';
import '../../environments/presentation/environments_section.dart';
import '../../environments/presentation/toolchains_section.dart';
import '../../flutter_apps/presentation/flutter_sdk_section.dart';
import '../../git/presentation/worktree_setup_page.dart';
import '../../notes/presentation/notes_settings_section.dart';
import '../../remote/presentation/machines_section.dart';
import '../../remote/presentation/remote_access_section.dart';
import '../../server/presentation/server_log_section.dart';
import '../../server/presentation/server_status_section.dart';
import '../../server/presentation/server_storage_section.dart';
import '../../snippets/presentation/snippets_settings_page.dart';
import '../../ssh/presentation/known_hosts_section.dart';
import '../../ssh/presentation/ssh_hosts_section.dart';
import '../../stores/presentation/stores_settings_section.dart';
import 'agent_detection_section.dart';
import 'agents_and_accounts_page.dart';
import 'usage_and_limits_section.dart';
import 'agent_path_section.dart';
import 'agent_tools_section.dart';
import 'agents_pages.dart';
import 'default_model_section.dart';
import 'devices_page.dart';
import 'diagnostics_page.dart';
import 'editor_files_sections.dart';
import 'external_app_section.dart';
import 'general_pages.dart';
import 'keyboard_section.dart';
import 'permissions_page.dart';
import 'settings_catalog.dart';
import 'settings_layout.dart';
import 'settings_theme.dart';
import 'side_panel_items_section.dart';
import 'terminal_colours_section.dart';
import 'terminal_pages.dart';
import 'tools_page.dart';
import 'watch_set_section.dart';

/// One settings page: its title and description, then each of its sections in
/// catalogue order, each wrapped so a deep link or a search hit can scroll to
/// it. The title is drawn on the page itself (spec §3, page titles): scrolled
/// away from the list, or under the narrow picker, a page still says what it
/// is.
///
/// Measures its own width once — it sits in the page's scroll view, never
/// under intrinsics — and hands "narrow" down through [SettingsNarrowScope],
/// so a split-pane page gets a smaller title and tighter gaps and its sections
/// and cards follow without measuring themselves.
class SettingsPageBody extends StatelessWidget {
  const SettingsPageBody({required this.page, super.key});

  final SettingsSectionId page;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = SettingsLayout.isNarrow(constraints.maxWidth, scaler);
        return SettingsNarrowScope(
          narrow: narrow,
          // The board's controls for every section on the page, whichever
          // feature built it.
          child: SettingsControlsTheme(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Board page header: the title (19, semibold) and its blurb
                // (12.5, muted) two pixels under it; the first section's own
                // 22 px sets it off from the rows.
                Semantics(
                  header: true,
                  child: Text(
                    page.label,
                    style: SettingsStyles.pageTitle(context, narrow: narrow),
                  ),
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  page.description,
                  style: SettingsStyles.pageBlurb(context),
                ),
                ...settingsPageChildren(page),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What [page] draws under its header, each section wrapped in its anchor so
/// a deep link or a search hit can scroll to it. Catalogue order, except on
/// Agents and accounts, which is laid out agent by agent (spec §6) and places
/// its anchors itself.
List<Widget> settingsPageChildren(SettingsSectionId page) =>
    page == SettingsSectionId.agents
    ? const [AgentsAndAccountsBody()]
    : [
        for (final anchor in page.anchors)
          _ShownSection(
            anchor: anchor,
            child: SettingsAnchorTarget(
              anchor: anchor,
              child: settingsSectionFor(anchor),
            ),
          ),
      ];

/// [child], unless this client hides [anchor]'s section
/// ([SettingsAnchor.shownWith]).
class _ShownSection extends ConsumerWidget {
  const _ShownSection({required this.anchor, required this.child});

  final SettingsAnchor anchor;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      anchor.shownWith(ref.watch(capabilitiesProvider))
      ? child
      : const SizedBox.shrink();
}

/// The widget that draws [anchor]. Every section is named once, here — except
/// that Agents and accounts lays its page out agent by agent
/// ([AgentsAndAccountsBody]); its account and default-model anchors name the
/// standalone sections they grew out of.
Widget settingsSectionFor(SettingsAnchor anchor) => switch (anchor) {
  SettingsAnchor.startup => const StartupSection(),
  SettingsAnchor.sessionView => const SessionViewSection(),
  SettingsAnchor.launcherHotkey => const LauncherHotkeySection(),
  SettingsAnchor.keyboard => const KeyboardSection(),
  SettingsAnchor.notifications => const NotificationsSection(),
  SettingsAnchor.about => const AboutSection(),
  SettingsAnchor.notes => const NotesSettingsSection(),
  SettingsAnchor.themeText => const ThemeTextSection(),
  SettingsAnchor.sidePanel => const SidePanelItemsSection(),
  SettingsAnchor.editor => const EditorSection(),
  SettingsAnchor.fileBrowsing => const FileBrowsingSection(),
  SettingsAnchor.externalTerminal => const ExternalAppSection(
    kind: ExternalAppKind.terminal,
  ),
  SettingsAnchor.externalEditor => const ExternalAppSection(
    kind: ExternalAppKind.editor,
  ),
  SettingsAnchor.defaultTerminal => const DefaultTerminalSection(),
  SettingsAnchor.terminalFont => const TerminalFontSection(),
  SettingsAnchor.terminalTheme => const TerminalColoursSection(),
  SettingsAnchor.terminalChords => const TerminalChordsSection(),
  SettingsAnchor.terminalAdvanced => const TerminalAdvancedSection(),
  SettingsAnchor.worktreeSetup => const WorktreeSetupPage(),
  SettingsAnchor.appProjects => const ProjectKindsSection(),
  SettingsAnchor.androidEmulators => const AndroidEmulatorsSection(),
  SettingsAnchor.iosSimulators => const IosSimulatorsSection(),
  SettingsAnchor.snippets => const SnippetsSettingsPage(),
  SettingsAnchor.variables => const EnvSecretsPage(),
  SettingsAnchor.github => const GithubAccessPage(),
  SettingsAnchor.automations => const AutomationsSettingsLink(
    anchor: SettingsAnchor.automations,
    section: AutomationsSection.automations,
  ),

  SettingsAnchor.defaultAgent => const DefaultAgentSection(),
  SettingsAnchor.defaultModel => const DefaultModelSection(),
  SettingsAnchor.detection => const AgentDetectionSection(),
  SettingsAnchor.executables => const AgentPathSection(),
  SettingsAnchor.checkpoints => const CheckpointSettingsSection(),
  SettingsAnchor.agentUpdates => const AgentUpdatesSection(),
  SettingsAnchor.claudeAccounts => const InstalledClaudeAccountsSection(),
  SettingsAnchor.codexAccounts => const InstalledCodexAccountsSection(),
  SettingsAnchor.usage => const UsageAndLimitsSection(),
  SettingsAnchor.permissionModes => const PermissionModesSection(),
  SettingsAnchor.mcpBridge => const McpBridgeSection(),
  SettingsAnchor.toolCatalogue => const AgentToolsSection(),
  SettingsAnchor.skills => const AgentSkillsSection(),
  SettingsAnchor.browser => const BrowserConsentSection(),
  SettingsAnchor.executionEnvironments => const EnvironmentsSection(),
  SettingsAnchor.sshHosts => const SshHostsSection(),
  SettingsAnchor.flutterSdk => const FlutterSdkSection(),
  SettingsAnchor.buildTooling => const ToolchainsSection(),
  SettingsAnchor.knownHosts => const KnownHostsSection(),
  SettingsAnchor.machines => const MachinesSection(),
  SettingsAnchor.serverStatus => const ServerStatusSection(),
  SettingsAnchor.serverLog => const ServerLogSection(),
  SettingsAnchor.serverStorage => const ServerStorageSection(),
  SettingsAnchor.remoteAccess => const RemoteAccessSection(),
  SettingsAnchor.storeCredentials => const StoresSettingsSection(),
  SettingsAnchor.debugMode => const DebugModeSection(),
  SettingsAnchor.logFile => const LogFileSection(),
  SettingsAnchor.scrollbackPersistence => const ScrollbackPersistenceSection(),
  SettingsAnchor.sessionWatching => const WatchSetSection(),
  SettingsAnchor.memoryFootprint => const MemoryFootprintSection(),
};

/// Hands out one key per section of the page on screen, so the screen can
/// scroll a section into view after the page is built.
class SettingsAnchorScope extends InheritedWidget {
  const SettingsAnchorScope({
    required this.keys,
    required super.child,
    this.revealing,
    super.key,
  });

  final Map<SettingsAnchor, GlobalKey> keys;

  /// The anchor a deep link is scrolling to, so a collapsed card holding it
  /// opens instead of being scrolled to shut.
  final SettingsAnchor? revealing;

  static GlobalKey? keyFor(BuildContext context, SettingsAnchor anchor) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SettingsAnchorScope>();
    return scope?.keys.putIfAbsent(
      anchor,
      () => GlobalKey(debugLabel: 'settings-${anchor.name}'),
    );
  }

  static SettingsAnchor? revealingOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsAnchorScope>()
      ?.revealing;

  @override
  bool updateShouldNotify(SettingsAnchorScope oldWidget) =>
      !identical(keys, oldWidget.keys) || revealing != oldWidget.revealing;
}

/// A section a deep link can land on.
class SettingsAnchorTarget extends StatelessWidget {
  const SettingsAnchorTarget({
    required this.anchor,
    required this.child,
    super.key,
  });

  final SettingsAnchor anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: SettingsAnchorScope.keyFor(context, anchor),
    child: child,
  );
}
