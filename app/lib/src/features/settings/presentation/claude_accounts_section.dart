import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/claude_accounts_controller.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import 'agent_account_widgets.dart';
import 'settings_catalog.dart';
import 'settings_section.dart';

/// Per-Claude-installation account management: one card per install, plus a
/// shared pool of saved accounts any install can switch to without re-auth.
class ClaudeAccountsSection extends ConsumerWidget {
  const ClaudeAccountsSection({required this.installations, super.key});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(claudeAccountsControllerProvider);
    final controller = ref.read(claudeAccountsControllerProvider.notifier);

    return SettingsSection(
      title: SettingsAnchor.claudeAccounts.heading,
      child: installations.isEmpty
          ? Text(
              'No Claude Code found. Find agents under Settings → Machines.',
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
                    SavedAccountRow(
                      title: account.email,
                      subtitle: [
                        if (account.organizationName != null)
                          account.organizationName!,
                        if (account.subscriptionType != null)
                          account.subscriptionType!,
                        if (account.capturedEnvironmentId != null)
                          'from ${account.capturedEnvironmentId}',
                      ].join(' · '),
                      forgetTooltip: 'Forget this saved account',
                      onForget: () => controller.forget(account),
                    ),
                ],
              ],
            ),
    );
  }
}

/// One card: one installation's account, with Refresh, Capture and Switch to.
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
    final environment = ref.watch(
      environmentLabelForIdProvider(_installation.environmentId),
    );

    return AgentAccountCardFrame(
      title: environment,
      busy: _busy,
      onRefresh: () =>
          ref.invalidate(claudeAuthSnapshotProvider(_installation)),
      current: snapshot.when(
        loading: () =>
            Text('Reading current account…', style: theme.textTheme.bodySmall),
        error: (e, _) => Text(
          'Could not read account: $e',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        data: (snap) => _currentAccount(theme, snap),
      ),
      onCapture: _busy
          ? null
          : () => _run(
              () => controller.captureCurrent(_installation),
              'Captured the current account.',
            ),
      switchMenu: accounts.isEmpty
          ? null
          : SwitchAccountMenu<ClaudeAccount>(
              enabled: !_busy,
              tooltip: 'Switch this install to a saved account',
              onSelected: (account) => _run(
                () => controller.switchTo(_installation, account),
                'Switched $environment to ${account.email}.',
              ),
              items: [
                // The account in force is the checked one, not a tick.
                for (final account in accounts)
                  DesktopMenuItem(
                    value: account,
                    enabled: !(activeAccount?.matches(account) ?? false),
                    selected: activeAccount?.matches(account) ?? false,
                    label: account.email,
                    icon: AppIcons.userCircle,
                  ),
              ],
            ),
    );
  }

  Widget _currentAccount(ThemeData theme, ClaudeAuthSnapshot snapshot) {
    if (!snapshot.isSignedIn) {
      return Text(
        'Not signed in. Run `claude` in this environment to sign in.',
        style: theme.textTheme.bodySmall,
      );
    }
    final expiresAt = snapshot.accessTokenExpiresAt;
    final bits = <String>[
      if (snapshot.subscriptionType != null) snapshot.subscriptionType!,
      if (snapshot.rateLimitTier != null) snapshot.rateLimitTier!,
      if (expiresAt != null)
        'token ${relativeExpiry(expiresAt, ref.watch(clockProvider).nowUtc())}',
    ];
    return SignedInAccount(
      title: snapshot.email!,
      details: [
        if (snapshot.organizationName != null) snapshot.organizationName!,
        if (bits.isNotEmpty) bits.join(' · '),
      ],
    );
  }
}
