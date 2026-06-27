import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/domain/agent_kind.dart';
import '../../environments/application/environments_controller.dart';
import '../../terminal/domain/terminal_profile.dart';
import '../application/settings_controller.dart';
import '../domain/app_theme_mode.dart';
import '../domain/permission_mode.dart';
import '../domain/settings.dart';

/// Settings (a full page): appearance, the default agent, identified agent
/// installations, and per-agent permission preferences for new vs. existing
/// sessions.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => const SettingsScreen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final installations = ref.watch(agentInstallationsControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(
          children: [
            Icon(Icons.settings_outlined, color: theme.colorScheme.tertiary),
            const SizedBox(width: Insets.sm),
            const Text('Settings'),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(Insets.xl),
            children: [
              _Section(
                title: 'APPEARANCE',
                child: SegmentedButton<AppThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: AppThemeMode.system,
                      icon: Icon(Icons.brightness_auto_outlined, size: 16),
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined, size: 16),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined, size: 16),
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (s) => controller.setThemeMode(s.first),
                ),
              ),
              Builder(
                builder: (context) {
                  final profiles = terminalProfilesFor(
                    ref.watch(environmentsControllerProvider),
                  );
                  final current = resolveTerminalProfile(
                    settings.defaultTerminalProfileId,
                    profiles,
                  );
                  return _Section(
                    title: 'DEFAULT TERMINAL',
                    child: DropdownButtonFormField<String>(
                      initialValue: current.id,
                      decoration: const InputDecoration(
                        labelText: 'Shell new terminals open with',
                      ),
                      items: [
                        for (final profile in profiles)
                          DropdownMenuItem(
                            value: profile.id,
                            child: Text(profile.label),
                          ),
                      ],
                      onChanged: (id) {
                        if (id != null) {
                          controller.setDefaultTerminalProfile(id);
                        }
                      },
                    ),
                  );
                },
              ),
              _Section(
                title: 'DEFAULT AGENT',
                child: DropdownButtonFormField<AgentKind?>(
                  initialValue: settings.defaultAgent,
                  decoration: const InputDecoration(
                    labelText: 'Pre-selected when starting a session',
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None')),
                    for (final kind in AgentKind.values)
                      DropdownMenuItem(
                        value: kind,
                        child: Text(_agentLabel(kind)),
                      ),
                  ],
                  onChanged: controller.setDefaultAgent,
                ),
              ),
              _Section(
                title: 'IDENTIFIED AGENTS',
                trailing: TextButton.icon(
                  onPressed: () => ref
                      .read(agentInstallationsControllerProvider.notifier)
                      .discoverAll(),
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('Discover'),
                ),
                child: installations.isEmpty
                    ? Text(
                        'No agents identified yet. Press Discover to scan your '
                        'environments.',
                        style: theme.textTheme.bodySmall,
                      )
                    : Column(
                        children: [
                          for (final i in installations)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.smart_toy_outlined,
                                size: 18,
                              ),
                              title: Text(_agentLabel(i.agentKind)),
                              subtitle: Text(
                                '${i.environmentId} · ${i.executable.path}'
                                '${i.version == null ? '' : ' · v${i.version}'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: kMonoFamily,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              _Section(
                title: 'PERMISSIONS',
                child: Column(
                  children: [
                    for (final kind in AgentKind.values)
                      _PermissionCard(
                        kind: kind,
                        permissions: settings.permissionsFor(kind),
                        onNew: (m) =>
                            controller.setNewSessionPermission(kind, m),
                        onExisting: (m) =>
                            controller.setExistingSessionPermission(kind, m),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _agentLabel(AgentKind kind) => switch (kind) {
    AgentKind.claudeCode => 'Claude Code',
    AgentKind.codex => 'Codex',
    AgentKind.antigravity => 'Antigravity',
  };
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.labelSmall)),
              ?trailing,
            ],
          ),
          const SizedBox(height: Insets.sm),
          child,
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.kind,
    required this.permissions,
    required this.onNew,
    required this.onExisting,
  });

  final AgentKind kind;
  final AgentPermissions permissions;
  final ValueChanged<PermissionMode> onNew;
  final ValueChanged<PermissionMode> onExisting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dangerous =
        permissions.newSessions.isDangerous ||
        permissions.existingSessions.isDangerous;
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              SettingsScreen._agentLabel(kind),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                Expanded(
                  child: _modeDropdown(
                    'New sessions',
                    permissions.newSessions,
                    onNew,
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: _modeDropdown(
                    'Existing sessions',
                    permissions.existingSessions,
                    onExisting,
                  ),
                ),
              ],
            ),
            if (dangerous)
              Padding(
                padding: const EdgeInsets.only(top: Insets.sm),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        'Bypass skips all permission prompts. Use only in trusted '
                        'repositories.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _modeDropdown(
    String label,
    PermissionMode value,
    ValueChanged<PermissionMode> onChanged,
  ) {
    return DropdownButtonFormField<PermissionMode>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final mode in PermissionMode.values)
          DropdownMenuItem(value: mode, child: Text(mode.label)),
      ],
      onChanged: (m) {
        if (m != null) onChanged(m);
      },
    );
  }
}
