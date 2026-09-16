import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import '../../app_projects/presentation/project_kinds_section.dart';
import '../../automations/presentation/automations_page.dart';
import '../../env_secrets/presentation/env_secrets_page.dart';
import '../../environments/presentation/environments_section.dart';
import '../../environments/presentation/toolchains_section.dart';
import '../../flutter_apps/presentation/flutter_sdk_section.dart';
import '../../git/presentation/worktree_setup_page.dart';
import '../../notes/presentation/notes_settings_section.dart';
import '../../remote/presentation/remote_access_section.dart';
import '../../snippets/presentation/snippets_settings_page.dart';
import '../../ssh/presentation/known_hosts_section.dart';
import '../../ssh/presentation/ssh_hosts_section.dart';
import 'agent_detection_section.dart';
import 'agent_path_section.dart';
import 'agent_tools_section.dart';
import 'agents_pages.dart';
import 'default_model_section.dart';
import 'devices_page.dart';
import 'diagnostics_page.dart';
import 'editor_files_sections.dart';
import 'external_app_section.dart';
import 'general_pages.dart';
import 'permissions_page.dart';
import 'settings_catalog.dart';
import 'terminal_pages.dart';
import 'tools_page.dart';
import 'watch_set_section.dart';

/// One settings page: its description, then each of its sections in catalogue
/// order, each wrapped so a deep link or a search hit can scroll to it.
class SettingsPageBody extends StatelessWidget {
  const SettingsPageBody({required this.page, super.key});

  final SettingsSectionId page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.lg),
          child: Text(
            page.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final anchor in page.anchors)
          SettingsAnchorTarget(
            anchor: anchor,
            child: settingsSectionFor(anchor),
          ),
      ],
    );
  }
}

/// The widget that draws [anchor]. Every section is named once, here.
Widget settingsSectionFor(SettingsAnchor anchor) => switch (anchor) {
  SettingsAnchor.startup => const StartupSection(),
  SettingsAnchor.launcherHotkey => const LauncherHotkeySection(),
  SettingsAnchor.notes => const NotesSettingsSection(),
  SettingsAnchor.themeText => const ThemeTextSection(),
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
  SettingsAnchor.terminalTheme => const TerminalThemeSection(),
  SettingsAnchor.terminalChords => const TerminalChordsSection(),
  SettingsAnchor.terminalAdvanced => const TerminalAdvancedSection(),
  SettingsAnchor.worktreeSetup => const WorktreeSetupPage(),
  SettingsAnchor.appProjects => const ProjectKindsSection(),
  SettingsAnchor.androidEmulators => const AndroidEmulatorsSection(),
  SettingsAnchor.iosSimulators => const IosSimulatorsSection(),
  SettingsAnchor.snippets => const SnippetsSettingsPage(),
  SettingsAnchor.variables => const EnvSecretsPage(),
  SettingsAnchor.automations => const AutomationsPage(),
  SettingsAnchor.defaultAgent => const DefaultAgentSection(),
  SettingsAnchor.defaultModel => const DefaultModelSection(),
  SettingsAnchor.detection => const AgentDetectionSection(),
  SettingsAnchor.executables => const AgentPathSection(),
  SettingsAnchor.claudeAccounts => const InstalledClaudeAccountsSection(),
  SettingsAnchor.codexAccounts => const InstalledCodexAccountsSection(),
  SettingsAnchor.usage => const InstalledUsageSection(),
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
  SettingsAnchor.remoteAccess => const RemoteAccessSection(),
  SettingsAnchor.debugMode => const DebugModeSection(),
  SettingsAnchor.logFile => const LogFileSection(),
  SettingsAnchor.scrollbackPersistence => const ScrollbackPersistenceSection(),
  SettingsAnchor.sessionWatching => const WatchSetSection(),
};

/// Hands out one key per section of the page on screen, so the screen can
/// scroll a section into view after the page is built.
class SettingsAnchorScope extends InheritedWidget {
  const SettingsAnchorScope({
    required this.keys,
    required super.child,
    super.key,
  });

  final Map<SettingsAnchor, GlobalKey> keys;

  static GlobalKey? keyFor(BuildContext context, SettingsAnchor anchor) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SettingsAnchorScope>();
    return scope?.keys.putIfAbsent(
      anchor,
      () => GlobalKey(debugLabel: 'settings-${anchor.name}'),
    );
  }

  @override
  bool updateShouldNotify(SettingsAnchorScope oldWidget) =>
      !identical(keys, oldWidget.keys);
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
