import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../agents/application/codex_accounts_controller.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import 'settings_section.dart';

/// The active Codex identity per installation and explicitly captured accounts.
/// Refresh is manual: no timer, no background scan, no vendor request.
class CodexAccountsSection extends ConsumerWidget {
  const CodexAccountsSection({required this.installations, super.key});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(codexAccountsControllerProvider);
    final controller = ref.read(codexAccountsControllerProvider.notifier);
    return SettingsSection(
      title: 'CODEX ACCOUNTS',
      child: installations.isEmpty
          ? Text(
              'No Codex installation identified. Press Discover under '
              'Environments first.',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final installation in installations)
                  _CodexInstallCard(installation: installation),
                if (accounts.isNotEmpty) ...[
                  const SizedBox(height: Insets.xs),
                  Text('CAPTURED ACCOUNTS', style: theme.textTheme.labelSmall),
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

class _CodexInstallCard extends ConsumerStatefulWidget {
  const _CodexInstallCard({required this.installation});

  final AgentInstallation installation;

  @override
  ConsumerState<_CodexInstallCard> createState() => _CodexInstallCardState();
}

class _CodexInstallCardState extends ConsumerState<_CodexInstallCard> {
  bool _busy = false;

  Future<void> _capture() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(codexAccountsControllerProvider.notifier)
          .captureCurrent(widget.installation);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Captured the current Codex account.')),
        );
      }
    } on CodexAuthException catch (error) {
      if (mounted) _error(error.message);
    } catch (error) {
      if (mounted) _error('Unexpected error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchTo(CodexAccount account) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(codexAccountsControllerProvider.notifier)
          .switchTo(widget.installation, account);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Switched Codex to ${account.email ?? account.accountId}.',
            ),
          ),
        );
      }
    } on CodexAuthException catch (error) {
      if (mounted) _error(error.message);
    } catch (error) {
      if (mounted) _error('Unexpected error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _error(String message) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: theme.colorScheme.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(codexAuthSnapshotProvider(widget.installation));
    final accounts = ref.watch(codexAccountsControllerProvider);
    final activeId = snapshot.asData?.value.accountId;
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
                        widget.installation.environmentId,
                      ),
                    ),
                    style: MonoStyles.body,
                    overflow: TextOverflow.ellipsis,
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
                    tooltip: 'Re-read the current Codex account',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref.invalidate(
                      codexAuthSnapshotProvider(widget.installation),
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
              error: (error, _) => Text(
                'Could not read account: $error',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              data: (value) => _CurrentAccount(snapshot: value),
            ),
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : _capture,
                  icon: const Icon(AppIcons.downloadSimple),
                  label: const Text('Capture current'),
                ),
                if (accounts.isNotEmpty)
                  PopupMenuButton<CodexAccount>(
                    enabled: !_busy,
                    tooltip: 'Switch this install to a captured account',
                    onSelected: _switchTo,
                    itemBuilder: (_) => [
                      for (final account in accounts)
                        DesktopMenuItem(
                          value: account,
                          enabled: activeId != account.accountId,
                          selected: activeId == account.accountId,
                          label: account.email ?? account.accountId,
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

  final CodexAuthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!snapshot.isSignedIn) {
      return Text(
        'Not signed in. Run `codex login` in this environment.',
        style: theme.textTheme.bodySmall,
      );
    }
    final title = snapshot.email ?? snapshot.accountId!;
    final details = <String>[
      if (snapshot.planType != null) snapshot.planType!,
      if (snapshot.accessTokenExpiresAt != null)
        _relativeExpiry(snapshot.accessTokenExpiresAt!),
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
                title,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (snapshot.email != null)
          Text(snapshot.accountId!, style: theme.textTheme.bodySmall),
        if (details.isNotEmpty)
          Text(details.join(' · '), style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _SavedAccountRow extends StatelessWidget {
  const _SavedAccountRow({required this.account, required this.onForget});

  final CodexAccount account;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = <String>[
      if (account.planType != null) account.planType!,
      if (account.capturedEnvironmentId != null)
        'from ${account.capturedEnvironmentId}',
    ];
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
                  account.email ?? account.accountId,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                if (details.isNotEmpty)
                  Text(
                    details.join(' · '),
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Forget this captured account',
            visualDensity: VisualDensity.compact,
            onPressed: onForget,
            icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
          ),
        ],
      ),
    );
  }
}

String _relativeExpiry(DateTime when) {
  final diff = when.difference(DateTime.now());
  if (diff.isNegative) return 'token expired';
  if (diff.inHours >= 24) return 'token expires in ${diff.inDays}d';
  if (diff.inHours >= 1) return 'token expires in ${diff.inHours}h';
  return 'token expires in ${diff.inMinutes}m';
}
