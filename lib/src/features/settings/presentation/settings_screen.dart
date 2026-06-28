import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:file_selector/file_selector.dart';
import 'package:picons/picons.dart';

import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/domain/agent_kind.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
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
            Icon(PiconsRegular.gearSix, color: theme.colorScheme.tertiary),
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
                      icon: Icon(PiconsRegular.circleHalf, size: 16),
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.light,
                      icon: Icon(PiconsRegular.sun, size: 16),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      icon: Icon(PiconsRegular.moon, size: 16),
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (s) => controller.setThemeMode(s.first),
                ),
              ),
              _Section(
                title: 'SYSTEM',
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.keepAwake,
                      onChanged: controller.setKeepAwake,
                      title: const Text('Keep system awake'),
                      subtitle: const Text(
                        'Prevent the display and system from sleeping while '
                        'Chitragupta is running.',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.closeToTray,
                      onChanged: controller.setCloseToTray,
                      title: const Text('Close to tray'),
                      subtitle: const Text(
                        'Hide to the system tray when the window is closed '
                        'instead of quitting.',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.autoStart,
                      onChanged: controller.setAutoStart,
                      title: const Text('Start at login'),
                      subtitle: const Text(
                        'Launch Chitragupta automatically when you sign in.',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.compactDensity,
                      onChanged: controller.setCompactDensity,
                      title: const Text('Compact density'),
                      subtitle: const Text(
                        'Denser lists and controls. Turn off for a roomier '
                        'layout.',
                      ),
                    ),
                  ],
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
              const _TerminalAppSection(),
              const _CodeEditorSection(),
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
                  icon: const Icon(PiconsRegular.magnifyingGlass, size: 16),
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
                                PiconsRegular.robot,
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
                      PiconsRegular.warning,
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

/// The external terminal app used to resume sessions (mini mode / open-in-
/// terminal): a detected terminal or a custom executable (browse or paste path).
class _TerminalAppSection extends ConsumerStatefulWidget {
  const _TerminalAppSection();

  @override
  ConsumerState<_TerminalAppSection> createState() =>
      _TerminalAppSectionState();
}

class _TerminalAppSectionState extends ConsumerState<_TerminalAppSection> {
  final _path = TextEditingController();

  @override
  void initState() {
    super.initState();
    _path.text = ref.read(settingsControllerProvider).customTerminalPath ?? '';
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Executables', extensions: ['exe']),
      ],
    );
    if (file == null) return;
    _path.text = file.path;
    ref
        .read(settingsControllerProvider.notifier)
        .setCustomTerminalPath(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final detected =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    final isCustom = settings.defaultSystemTerminalId == 'custom';
    final current = settings.defaultSystemTerminalId == null && detected.isEmpty
        ? 'custom'
        : (settings.defaultSystemTerminalId ??
              (detected.isNotEmpty ? detected.first.id : 'custom'));

    return _Section(
      title: 'TERMINAL APP (resumes sessions)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: current,
            decoration: const InputDecoration(labelText: 'Open sessions in'),
            items: [
              for (final t in detected)
                DropdownMenuItem(value: t.id, child: Text(t.label)),
              const DropdownMenuItem(
                value: 'custom',
                child: Text('Custom executable…'),
              ),
            ],
            onChanged: (v) {
              if (v == null) return;
              if (v == 'custom') {
                controller.setCustomTerminalPath(_path.text.trim());
              } else {
                controller.setDefaultSystemTerminal(v);
              }
            },
          ),
          if (isCustom) ...[
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Terminal executable path',
                      hintText: r'C:\path\to\terminal.exe',
                    ),
                    onChanged: (v) =>
                        controller.setCustomTerminalPath(v.trim()),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(PiconsRegular.folderOpen, size: 16),
                  label: const Text('Browse'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'The session\'s agent runs in this app (cwd set to the repo); flags '
              'vary by terminal, so it is best-effort.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The code editor used by "open in editor" on projects: a detected editor
/// (VS Code, Zed) or a custom executable (browse or paste path).
class _CodeEditorSection extends ConsumerStatefulWidget {
  const _CodeEditorSection();

  @override
  ConsumerState<_CodeEditorSection> createState() => _CodeEditorSectionState();
}

class _CodeEditorSectionState extends ConsumerState<_CodeEditorSection> {
  final _path = TextEditingController();

  @override
  void initState() {
    super.initState();
    _path.text = ref.read(settingsControllerProvider).customEditorPath ?? '';
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Executables', extensions: ['exe']),
      ],
    );
    if (file == null) return;
    _path.text = file.path;
    ref
        .read(settingsControllerProvider.notifier)
        .setCustomEditorPath(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final detected =
        ref.watch(availableCodeEditorsProvider).asData?.value ?? const [];
    final isCustom = settings.defaultCodeEditorId == 'custom';
    final current = settings.defaultCodeEditorId == null && detected.isEmpty
        ? 'custom'
        : (settings.defaultCodeEditorId ??
              (detected.isNotEmpty ? detected.first.id : 'custom'));

    return _Section(
      title: 'CODE EDITOR (open in editor)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: current,
            decoration: const InputDecoration(labelText: 'Open folders in'),
            items: [
              for (final e in detected)
                DropdownMenuItem(value: e.id, child: Text(e.label)),
              const DropdownMenuItem(
                value: 'custom',
                child: Text('Custom executable…'),
              ),
            ],
            onChanged: (v) {
              if (v == null) return;
              if (v == 'custom') {
                controller.setCustomEditorPath(_path.text.trim());
              } else {
                controller.setDefaultCodeEditor(v);
              }
            },
          ),
          if (isCustom) ...[
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Editor executable path',
                      hintText: r'C:\path\to\editor.exe',
                    ),
                    onChanged: (v) => controller.setCustomEditorPath(v.trim()),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(PiconsRegular.folderOpen, size: 16),
                  label: const Text('Browse'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'The editor opens with the folder path as its argument '
              '(e.g. `editor.exe <folder>`).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
