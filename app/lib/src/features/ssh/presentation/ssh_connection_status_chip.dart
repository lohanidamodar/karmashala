import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../data/ssh_client.dart';
import 'package:karmashala_environments/ssh.dart';

/// How a connection state reads to a user, in one line. Pure, so the wording is
/// testable and one place decides what "retry scheduled" is called.
({String label, IconData icon}) describeSshStatus(SshConnectionState state) =>
    switch (state.status) {
      SshConnectionStatus.idle => (
        label: 'Not connected',
        icon: AppIcons.circle,
      ),
      SshConnectionStatus.connecting => (
        label: state.attempt == 0
            ? 'Connecting…'
            : 'Connecting… (attempt ${state.attempt + 1})',
        icon: AppIcons.arrowsClockwise,
      ),
      SshConnectionStatus.connected => (
        label: 'Connected',
        icon: AppIcons.checkCircle,
      ),
      SshConnectionStatus.disconnected => (
        label: state.nextRetryIn == null
            ? 'Disconnected'
            : 'Reconnecting in ${_seconds(state.nextRetryIn!)}',
        icon: AppIcons.warningCircle,
      ),
      SshConnectionStatus.failed => (label: 'Failed', icon: AppIcons.xCircle),
    };

String _seconds(Duration d) => d.inMilliseconds < 1000
    ? '${d.inMilliseconds} ms'
    : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

/// The connection state of one saved host, live. Never renders "not connected"
/// for a failure: a broken host must not look like one nobody has tried.
class SshConnectionStatusChip extends ConsumerWidget {
  const SshConnectionStatusChip({
    required this.hostId,
    this.showError = true,
    super.key,
  });

  final String hostId;

  /// Whether to print the failure reason beside the chip.
  final bool showError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(sshConnectionStateProvider(hostId)).value ??
        const SshConnectionState.idle();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final described = describeSshStatus(state);
    final colour = switch (state.status) {
      SshConnectionStatus.idle => scheme.onSurfaceVariant,
      SshConnectionStatus.connecting => scheme.tertiary,
      SshConnectionStatus.connected => scheme.primary,
      SshConnectionStatus.disconnected => scheme.tertiary,
      SshConnectionStatus.failed => scheme.error,
    };
    final error = state.error;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(described.icon, size: Chrome.iconAction, color: colour),
        const SizedBox(width: Insets.xs),
        Text(
          described.label,
          style: theme.textTheme.labelMedium?.copyWith(color: colour),
        ),
        if (showError && error != null && !state.isConnected) ...[
          const SizedBox(width: Insets.sm),
          Flexible(
            child: Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: colour),
            ),
          ),
        ],
      ],
    );
  }
}
