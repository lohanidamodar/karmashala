import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/known_hosts_controller.dart';
import '../domain/ssh_host_key.dart';

/// The one SSH failure that is not a nuisance but a warning.
///
/// A host presenting a different key from the one we pinned is refused by
/// `SshHostKeyVerifier` before any handler is consulted, and the stored key is
/// never overwritten. There is deliberately **no "connect anyway"** here: an
/// interface that lets you click through a changed host key is not host key
/// verification. What there is instead is the same escape hatch OpenSSH has —
/// forget the stored key — as an explicit, separate, confirmed act, after which
/// the next connection is a first connection and prompts for the new
/// fingerprint on its own.
class HostKeyChangedAlert extends StatelessWidget {
  const HostKeyChangedAlert({
    required this.presentation,
    this.onForgotten,
    super.key,
  });

  final HostKeyPresentation presentation;

  /// Called after the pinned key has been forgotten, so the caller can clear a
  /// stale error and let the user retry.
  final VoidCallback? onForgotten;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final known = presentation.known;

    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: scheme.error),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.warning, size: 18, color: scheme.error),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  'REMOTE HOST IDENTIFICATION HAS CHANGED',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.error,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            'Someone could be eavesdropping on you right now '
            '(man-in-the-middle attack), or ${presentation.host}:'
            '${presentation.port} was legitimately rebuilt. The connection was '
            'refused and the key that is pinned for this address was left '
            'untouched.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.md),
          if (known != null)
            _Fingerprint(
              label: 'Pinned',
              keyType: known.keyType,
              value: known.fingerprint,
            ),
          const SizedBox(height: Insets.xs),
          _Fingerprint(
            label: 'Offered now',
            keyType: presentation.keyType,
            value: presentation.fingerprint,
            highlight: true,
          ),
          const SizedBox(height: Insets.md),
          Text(
            'If — and only if — you know this host was rebuilt, forget the '
            'pinned key. The next connection is then treated as a first '
            'connection and asks you to check the new fingerprint.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _forget(context),
              icon: const Icon(AppIcons.trash, size: 16),
              label: const Text('Forget the pinned key…'),
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _forget(BuildContext context) async {
    final forgotten = await ForgetHostKeyDialog.show(
      context,
      host: presentation.host,
      port: presentation.port,
    );
    if (forgotten) onForgotten?.call();
  }
}

class _Fingerprint extends StatelessWidget {
  const _Fingerprint({
    required this.label,
    required this.keyType,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String keyType;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label · $keyType', style: theme.textTheme.labelSmall),
        SelectableText(
          value,
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 12,
            color: highlight ? theme.colorScheme.error : null,
          ),
        ),
      ],
    );
  }
}

/// Confirms forgetting the pinned key for one `host:port`.
///
/// Separate from the alert, and worded so it is clear this does **not** accept
/// the new key — it only makes the address unknown again, which is the only
/// thing that is ever safe to do automatically on the user's say-so.
class ForgetHostKeyDialog extends ConsumerWidget {
  const ForgetHostKeyDialog({
    required this.host,
    required this.port,
    super.key,
  });

  final String host;
  final int port;

  /// Returns true when the key was forgotten.
  static Future<bool> show(
    BuildContext context, {
    required String host,
    required int port,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => ForgetHostKeyDialog(host: host, port: port),
      ) ??
      false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(AppIcons.warning, color: theme.colorScheme.error),
      title: const Text('Forget the pinned host key?'),
      content: SizedBox(
        width: 460,
        child: Text(
          'Karmashala will stop recognising $host:$port. The next connection '
          'is treated as a first connection: you will be shown the '
          'fingerprint it presents and asked whether to trust it.\n\n'
          'Do this only if you know why the key changed — a rebuilt machine, a '
          'reinstalled server. If you do not, the change itself is the warning.',
          style: theme.textTheme.bodyMedium,
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep it'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () {
            ref.read(knownHostsControllerProvider.notifier).forget(host, port);
            Navigator.of(context).pop(true);
          },
          child: const Text('Forget it'),
        ),
      ],
    );
  }
}
