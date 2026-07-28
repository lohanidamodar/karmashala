import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:file_selector/file_selector.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/claude_accounts_controller.dart';
import '../../agents/data/claude_auth_service.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_kind.dart';
import '../../agents/domain/claude_account.dart';
import '../../agents/domain/claude_auth_snapshot.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/domain/terminal_profile.dart';
import '../application/settings_controller.dart';
import '../domain/app_theme_mode.dart';
import '../domain/mini_position.dart';
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
            Icon(AppIcons.gearSix, color: theme.colorScheme.tertiary),
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
                      icon: Icon(AppIcons.circleHalf, size: 16),
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.light,
                      icon: Icon(AppIcons.sun, size: 16),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      icon: Icon(AppIcons.moon, size: 16),
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
              const _MiniLauncherSection(),
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
                  icon: const Icon(AppIcons.magnifyingGlass, size: 16),
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
                              leading: const Icon(AppIcons.robot, size: 18),
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
              _ClaudeAccountsSection(
                installations: installations
                    .where((i) => i.agentKind == AgentKind.claudeCode)
                    .toList(),
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
                      AppIcons.warning,
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
    // The dropdown value must match exactly one item, so clamp the saved
    // selection to a currently-valid option. The saved terminal can be missing
    // from `detected` while the async probe is still loading (or if it was
    // uninstalled); without this clamp DropdownButtonFormField throws and the
    // settings screen flashes a red error until the probe resolves.
    final validIds = <String>{for (final t in detected) t.id, 'custom'};
    final saved = settings.defaultSystemTerminalId;
    final current = (saved != null && validIds.contains(saved))
        ? saved
        : (detected.isNotEmpty ? detected.first.id : 'custom');
    final isCustom = current == 'custom';

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
                  icon: const Icon(AppIcons.folderOpen, size: 16),
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
                  icon: const Icon(AppIcons.folderOpen, size: 16),
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

/// Mini-launcher preferences: where the compact window appears on screen. The
/// six choices are laid out spatially (top row / bottom row) so the grid mirrors
/// the eventual on-screen position.
class _MiniLauncherSection extends ConsumerWidget {
  const _MiniLauncherSection();

  static const _rows = <List<MiniPosition>>[
    [MiniPosition.topLeft, MiniPosition.topCenter, MiniPosition.topRight],
    [
      MiniPosition.bottomLeft,
      MiniPosition.bottomCenter,
      MiniPosition.bottomRight,
    ],
  ];

  static const _icons = <MiniPosition, IconData>{
    MiniPosition.topLeft: AppIcons.arrowUpLeft,
    MiniPosition.topCenter: AppIcons.arrowUp,
    MiniPosition.topRight: AppIcons.arrowUpRight,
    MiniPosition.bottomLeft: AppIcons.arrowDownLeft,
    MiniPosition.bottomCenter: AppIcons.arrowDown,
    MiniPosition.bottomRight: AppIcons.arrowDownRight,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final current = ref.watch(
      settingsControllerProvider.select((s) => s.miniPosition),
    );
    final controller = ref.read(settingsControllerProvider.notifier);

    Widget cell(MiniPosition pos) {
      final selected = pos == current;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Tooltip(
            message: pos.label,
            child: Material(
              color: selected
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => controller.setMiniPosition(pos),
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Icon(
                    _icons[pos],
                    size: 18,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return _Section(
      title: 'MINI LAUNCHER',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Window position', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 2),
          Text(
            'Where the compact launcher appears, inset from the screen edge.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.sm),
          for (final row in _MiniLauncherSection._rows)
            Row(children: [for (final pos in row) cell(pos)]),
        ],
      ),
    );
  }
}

/// Per-Claude-installation account management: one card per install showing the
/// logged-in account (with a Refresh and Capture), plus a single shared pool of
/// saved accounts any install can be switched to — all without re-auth.
class _ClaudeAccountsSection extends ConsumerWidget {
  const _ClaudeAccountsSection({required this.installations});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(claudeAccountsControllerProvider);
    final controller = ref.read(claudeAccountsControllerProvider.notifier);

    return _Section(
      title: 'CLAUDE ACCOUNTS',
      child: installations.isEmpty
          ? Text(
              'No Claude Code installation identified. Press Discover under '
              'Identified Agents first.',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final installation in installations)
                  _ClaudeInstallCard(installation: installation),
                if (accounts.isNotEmpty) ...[
                  const SizedBox(height: Insets.xs),
                  Text(
                    'SAVED ACCOUNTS (shared across installs)',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: Insets.xs),
                  for (final account in accounts)
                    _SavedAccountRow(
                      account: account,
                      onForget: () => controller.forget(account),
                    ),
                ],
              ],
            ),
    );
  }
}

/// One card: the current account for a single Claude installation, with Refresh,
/// Capture, and a "Switch to" menu over the shared saved-account pool.
class _ClaudeInstallCard extends ConsumerStatefulWidget {
  const _ClaudeInstallCard({required this.installation});

  final AgentInstallation installation;

  @override
  ConsumerState<_ClaudeInstallCard> createState() => _ClaudeInstallCardState();
}

class _ClaudeInstallCardState extends ConsumerState<_ClaudeInstallCard> {
  bool _busy = false;

  AgentInstallation get _installation => widget.installation;

  Future<void> _run(Future<void> Function() action, String successMessage) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) _notify(successMessage);
    } on ClaudeAuthException catch (e) {
      if (mounted) _notify(e.message, isError: true);
    } catch (e) {
      if (mounted) _notify('Unexpected error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String message, {bool isError = false}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? theme.colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(claudeAuthSnapshotProvider(_installation));
    final accounts = ref.watch(claudeAccountsControllerProvider);
    final controller = ref.read(claudeAccountsControllerProvider.notifier);
    final activeAccount = snapshot.asData?.value;

    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(AppIcons.robot, size: 18),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    _installation.environmentId,
                    style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Re-read the current account',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref.invalidate(
                      claudeAuthSnapshotProvider(_installation),
                    ),
                    icon: const Icon(AppIcons.arrowsClockwise, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: Insets.sm),
            snapshot.when(
              loading: () => Text(
                'Reading current account…',
                style: theme.textTheme.bodySmall,
              ),
              error: (e, _) => Text(
                'Could not read account: $e',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              data: (snap) => _CurrentAccount(snapshot: snap),
            ),
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => controller.captureCurrent(_installation),
                          'Captured the current account.',
                        ),
                  icon: const Icon(AppIcons.downloadSimple, size: 16),
                  label: const Text('Capture current'),
                ),
                if (accounts.isNotEmpty)
                  PopupMenuButton<ClaudeAccount>(
                    enabled: !_busy,
                    tooltip: 'Switch this install to a saved account',
                    onSelected: (account) => _run(
                      () => controller.switchTo(_installation, account),
                      'Switched ${_installation.environmentId} to '
                      '${account.email}.',
                    ),
                    itemBuilder: (_) => [
                      for (final account in accounts)
                        PopupMenuItem(
                          value: account,
                          enabled: !(activeAccount?.matches(account) ?? false),
                          child: Row(
                            children: [
                              Expanded(child: Text(account.email)),
                              if (activeAccount?.matches(account) ?? false)
                                Icon(
                                  AppIcons.checkCircle,
                                  size: 14,
                                  color: theme.colorScheme.primary,
                                ),
                            ],
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.sm,
                        vertical: Insets.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(AppIcons.arrowsClockwise, size: 15),
                          const SizedBox(width: Insets.xs),
                          const Text('Switch to'),
                          Icon(AppIcons.caretDown, size: 14),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentAccount extends StatelessWidget {
  const _CurrentAccount({required this.snapshot});

  final ClaudeAuthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!snapshot.isSignedIn) {
      return Text(
        'Not signed in. Run `claude` in this environment to sign in.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final bits = <String>[
      if (snapshot.subscriptionType != null) snapshot.subscriptionType!,
      if (snapshot.rateLimitTier != null) snapshot.rateLimitTier!,
      if (snapshot.accessTokenExpiresAt != null)
        'token ${_relativeExpiry(snapshot.accessTokenExpiresAt!)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              AppIcons.checkCircle,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                snapshot.email!,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (snapshot.organizationName != null)
          Text(
            snapshot.organizationName!,
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        if (bits.isNotEmpty)
          Text(
            bits.join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// A row in the shared saved-account pool. Switching happens from an install
/// card (which knows the target environment); here we only display and forget.
class _SavedAccountRow extends StatelessWidget {
  const _SavedAccountRow({required this.account, required this.onForget});

  final ClaudeAccount account;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      if (account.organizationName != null) account.organizationName!,
      if (account.subscriptionType != null) account.subscriptionType!,
      if (account.capturedEnvironmentId != null)
        'from ${account.capturedEnvironmentId}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(AppIcons.circle, size: 8),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.email,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Forget this saved account',
            visualDensity: VisualDensity.compact,
            onPressed: onForget,
            icon: const Icon(AppIcons.trash, size: 15),
          ),
        ],
      ),
    );
  }
}

/// A human-readable relative expiry, e.g. "expires in 3h" / "expired".
String _relativeExpiry(DateTime when) {
  final diff = when.difference(DateTime.now());
  if (diff.isNegative) return 'expired';
  if (diff.inHours >= 24) return 'expires in ${diff.inDays}d';
  if (diff.inHours >= 1) return 'expires in ${diff.inHours}h';
  return 'expires in ${diff.inMinutes}m';
}
