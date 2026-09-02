import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/application/claude_accounts_controller.dart';
import '../../agents/data/agent_usage_service.dart';
import '../../agents/data/claude_auth_service.dart';
import '../../agents/domain/agent_ids.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_registry.dart';
import '../../agents/domain/agent_usage.dart';
import '../../agents/domain/claude_account.dart';
import '../../agents/domain/claude_auth_snapshot.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../application/settings_controller.dart';
import 'agent_detection_section.dart';
import '../domain/permission_mode.dart';
import '../domain/settings.dart';
import 'settings_row.dart';
import 'settings_section.dart';

String _agentLabel(String agentId) =>
    AgentRegistry.builtIn.displayNameFor(agentId);

/// Settings → Agents: the default agent, Claude account management and the
/// vendor usage windows.
class AgentsPage extends ConsumerWidget {
  const AgentsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final installations = ref.watch(agentInstallationsControllerProvider);
    // Offer every discovered installation (e.g. Claude on WSL vs Claude on
    // Windows), not just the kind. Clamp the saved value so the dropdown never
    // holds an id with no matching item.
    final currentId =
        installations.any((i) => i.id == settings.defaultAgentInstallationId)
        ? settings.defaultAgentInstallationId
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'DEFAULT AGENT',
          child: installations.isEmpty
              ? Text(
                  'No agents found. Press "Detect agents" below to search '
                  'your environments again.',
                  style: theme.textTheme.bodySmall,
                )
              : SettingsRow(
                  label: 'Pre-selected when starting a session',
                  control: DropdownButtonFormField<String?>(
                    initialValue: currentId,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None')),
                      for (final install in installations)
                        DropdownMenuItem(
                          value: install.id,
                          child: Text(
                            '${_agentLabel(install.agentId)} · '
                            '${ref.watch(environmentLabelForIdProvider(install.environmentId))}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      final install = id == null
                          ? null
                          : installations.firstWhere((i) => i.id == id);
                      controller.setDefaultAgentInstallation(
                        install?.agentId,
                        install?.id,
                      );
                    },
                  ),
                ),
        ),
        const AgentDetectionSection(),
        ClaudeAccountsSection(
          installations: installations
              .where((i) => i.agentId == AgentIds.claudeCode)
              .toList(),
        ),
        UsageSection(
          // An allowlist, not a blocklist: an agent we have no usage
          // endpoint for is simply not offered one.
          installations: installations
              .where(
                (i) =>
                    i.agentId == AgentIds.claudeCode ||
                    i.agentId == AgentIds.codex,
              )
              .toList(),
        ),
      ],
    );
  }
}

/// Settings → Permissions: per-agent permission preferences for new and
/// existing sessions.
class PermissionsPage extends ConsumerWidget {
  const PermissionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: 'PERMISSIONS',
      child: Column(
        children: [
          for (final descriptor in AgentRegistry.builtIn.descriptors)
            _PermissionCard(
              agentId: descriptor.id,
              permissions: settings.permissionsFor(descriptor.id),
              onNew: (m) =>
                  controller.setNewSessionPermission(descriptor.id, m),
              onExisting: (m) =>
                  controller.setExistingSessionPermission(descriptor.id, m),
            ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.agentId,
    required this.permissions,
    required this.onNew,
    required this.onExisting,
  });

  final String agentId;
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
            Text(_agentLabel(agentId), style: theme.textTheme.titleSmall),
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
            const SizedBox(height: Insets.xs),
            // Says which way the precedence runs, because the natural reading
            // of a settings screen is the opposite one: these are the modes a
            // session starts under **until it chooses**, and a session that has
            // chosen keeps its own when this changes.
            Text(
              'Defaults for sessions that have not chosen a mode of their own. '
              'A mode picked on a session keeps that session, even after this '
              'changes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (dangerous)
              Padding(
                padding: const EdgeInsets.only(top: Insets.sm),
                child: Row(
                  children: [
                    Icon(
                      AppIcons.warning,
                      size: Chrome.icon,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        'Bypass skips all permission prompts. Use only in '
                        'trusted repositories.',
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

/// Usage / limits per agent installation (Claude + Codex): fetched on demand
/// from the vendor OAuth endpoints using the token each install already stores.
class UsageSection extends StatelessWidget {
  const UsageSection({required this.installations, super.key});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsSection(
      title: 'USAGE & LIMITS',
      child: installations.isEmpty
          ? Text(
              'No Claude or Codex installation identified.',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              children: [
                for (final installation in installations)
                  _UsageCard(installation: installation),
              ],
            ),
    );
  }
}

class _UsageCard extends ConsumerStatefulWidget {
  const _UsageCard({required this.installation});

  final AgentInstallation installation;

  @override
  ConsumerState<_UsageCard> createState() => _UsageCardState();
}

class _UsageCardState extends ConsumerState<_UsageCard> {
  bool _loading = false;
  AgentUsage? _usage;
  String? _error;

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final environments = ref.read(executionEnvironmentDaoProvider).getAll();
      final usage = await ref
          .read(agentUsageServiceProvider)
          .fetch(widget.installation, environments);
      if (mounted) setState(() => _usage = usage);
    } on UsageException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _agentLabel(widget.installation.agentId);
    final usage = _usage;
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$label · '
                    '${ref.watch(environmentLabelForIdProvider(widget.installation.environmentId))}',
                    style: MonoStyles.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton.icon(
                    onPressed: _fetch,
                    icon: const Icon(
                      AppIcons.arrowsClockwise,
                      size: Chrome.iconAction,
                    ),
                    label: Text(usage == null ? 'Check usage' : 'Refresh'),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.xs),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (usage != null) ...[
              const SizedBox(height: Insets.sm),
              if (usage.isEmpty)
                Text(
                  'No usage windows reported.',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (final window in usage.windows) _UsageBar(window: window),
            ],
          ],
        ),
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.window});

  final UsageWindow window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = (window.percent / 100).clamp(0.0, 1.0);
    final semantic = SemanticColors.of(context);
    final color = window.percent >= 95
        ? semantic.failure
        : window.percent >= 80
        ? semantic.attention
        : theme.colorScheme.primary;
    final reset = window.resetsAt == null
        ? ''
        : ' · resets ${_relativeReset(window.resetsAt!)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(window.label, style: theme.textTheme.bodySmall),
              ),
              Text(
                '${window.percent.toStringAsFixed(0)}%$reset',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// A short relative reset time, e.g. "in 3h" / "in 2d" / "soon".
String _relativeReset(DateTime when) {
  final diff = when.difference(DateTime.now());
  if (diff.isNegative) return 'soon';
  if (diff.inDays >= 1) return 'in ${diff.inDays}d';
  if (diff.inHours >= 1) return 'in ${diff.inHours}h';
  return 'in ${diff.inMinutes}m';
}

/// Per-Claude-installation account management: one card per install showing the
/// logged-in account (with a Refresh and Capture), plus a single shared pool of
/// saved accounts any install can be switched to — all without re-auth.
class ClaudeAccountsSection extends ConsumerWidget {
  const ClaudeAccountsSection({required this.installations, super.key});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(claudeAccountsControllerProvider);
    final controller = ref.read(claudeAccountsControllerProvider.notifier);

    return SettingsSection(
      title: 'CLAUDE ACCOUNTS',
      child: installations.isEmpty
          ? Text(
              'No Claude Code installation identified. Press Discover under '
              'Environments first.',
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

  Future<void> _run(
    Future<void> Function() action,
    String successMessage,
  ) async {
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
                const Icon(AppIcons.robot, size: Chrome.iconTitle),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    ref.watch(
                      environmentLabelForIdProvider(
                        _installation.environmentId,
                      ),
                    ),
                    style: MonoStyles.body,
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
                    icon: const Icon(AppIcons.arrowsClockwise),
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
                  icon: const Icon(AppIcons.downloadSimple),
                  label: const Text('Capture current'),
                ),
                if (accounts.isNotEmpty)
                  PopupMenuButton<ClaudeAccount>(
                    enabled: !_busy,
                    tooltip: 'Switch this install to a saved account',
                    onSelected: (account) => _run(
                      () => controller.switchTo(_installation, account),
                      'Switched '
                      '${ref.read(environmentLabelForIdProvider(_installation.environmentId))} to '
                      '${account.email}.',
                    ),
                    itemBuilder: (_) => [
                      // The account already in force is the checked one, not a
                      // row with a tick tacked on the far end.
                      for (final account in accounts)
                        DesktopMenuItem(
                          value: account,
                          enabled: !(activeAccount?.matches(account) ?? false),
                          selected: activeAccount?.matches(account) ?? false,
                          label: account.email,
                          icon: AppIcons.userCircle,
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
                          const Icon(
                            AppIcons.arrowsClockwise,
                            size: Chrome.iconAction,
                          ),
                          const SizedBox(width: Insets.xs),
                          const Text('Switch to'),
                          Icon(AppIcons.caretDown, size: Chrome.iconAction),
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
        style: theme.textTheme.bodySmall,
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
              size: Chrome.icon,
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
          Text(bits.join(' · '), style: theme.textTheme.bodySmall),
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
          // A bullet in front of the account, not a glyph — same call as the
          // project card's running badge.
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
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Forget this saved account',
            visualDensity: VisualDensity.compact,
            onPressed: onForget,
            icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
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
