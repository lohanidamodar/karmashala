import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/codex_accounts_controller.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import 'agent_account_widgets.dart';
import 'settings_catalog.dart';
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
      title: SettingsAnchor.codexAccounts.heading,
      child: installations.isEmpty
          ? Text(
              'No Codex found. Press Discover under Environments.',
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
                    SavedAccountRow(
                      title: account.email ?? account.accountId,
                      subtitle: [
                        if (account.planType != null) account.planType!,
                        if (account.capturedEnvironmentId != null)
                          'from ${account.capturedEnvironmentId}',
                      ].join(' · '),
                      forgetTooltip: 'Forget this captured account',
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

  AgentInstallation get _installation => widget.installation;

  Future<void> _run(
    Future<void> Function() action,
    String successMessage,
  ) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) _notify(successMessage);
    } on CodexAuthException catch (error) {
      if (mounted) _notify(error.message, isError: true);
    } catch (error) {
      if (mounted) _notify('Unexpected error: $error', isError: true);
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
    final snapshot = ref.watch(codexAuthSnapshotProvider(_installation));
    final accounts = ref.watch(codexAccountsControllerProvider);
    final controller = ref.read(codexAccountsControllerProvider.notifier);
    final activeId = snapshot.asData?.value.accountId;

    return AgentAccountCardFrame(
      title: ref.watch(
        environmentLabelForIdProvider(_installation.environmentId),
      ),
      busy: _busy,
      refreshTooltip: 'Re-read the current Codex account',
      onRefresh: () => ref.invalidate(codexAuthSnapshotProvider(_installation)),
      current: snapshot.when(
        loading: () =>
            Text('Reading current account…', style: theme.textTheme.bodySmall),
        error: (error, _) => Text(
          'Could not read account: $error',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        data: (value) => _currentAccount(theme, value),
      ),
      onCapture: _busy
          ? null
          : () => _run(
              () => controller.captureCurrent(_installation),
              'Captured the current Codex account.',
            ),
      switchMenu: accounts.isEmpty
          ? null
          : SwitchAccountMenu<CodexAccount>(
              enabled: !_busy,
              tooltip: 'Switch this install to a captured account',
              onSelected: (account) => _run(
                () => controller.switchTo(_installation, account),
                'Switched Codex to ${account.email ?? account.accountId}.',
              ),
              items: [
                for (final account in accounts)
                  DesktopMenuItem(
                    value: account,
                    enabled: activeId != account.accountId,
                    selected: activeId == account.accountId,
                    label: account.email ?? account.accountId,
                    icon: AppIcons.userCircle,
                  ),
              ],
            ),
    );
  }

  Widget _currentAccount(ThemeData theme, CodexAuthSnapshot snapshot) {
    if (!snapshot.isSignedIn) {
      return Text(
        'Not signed in. Run `codex login` in this environment.',
        style: theme.textTheme.bodySmall,
      );
    }
    final expiresAt = snapshot.accessTokenExpiresAt;
    final details = <String>[
      if (snapshot.planType != null) snapshot.planType!,
      if (expiresAt != null)
        'token ${relativeExpiry(expiresAt, ref.watch(clockProvider).nowUtc())}',
    ];
    return SignedInAccount(
      title: snapshot.email ?? snapshot.accountId!,
      details: [
        if (snapshot.email != null) snapshot.accountId!,
        if (details.isNotEmpty) details.join(' · '),
      ],
    );
  }
}
