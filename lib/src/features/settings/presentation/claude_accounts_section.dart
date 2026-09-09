import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../agents/application/claude_accounts_controller.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import 'settings_section.dart';

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
