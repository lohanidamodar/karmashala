import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../domain/ssh_host_key.dart';

/// The public-key file on the server whose fingerprint should match [keyType],
/// so the dialog can tell the user exactly what to run over there.
///
/// Pure, and deliberately conservative: an algorithm we do not recognise gets no
/// invented filename, because a wrong instruction is worse than none when the
/// whole point is that the user compares two values.
String? hostKeyPublicKeyFile(String keyType) {
  final family = switch (keyType) {
    'ssh-ed25519' => 'ed25519',
    'sk-ssh-ed25519@openssh.com' => 'ed25519_sk',
    'ssh-rsa' || 'rsa-sha2-256' || 'rsa-sha2-512' => 'rsa',
    'ssh-dss' => 'dsa',
    _ when keyType.startsWith('ecdsa-sha2-') => 'ecdsa',
    _ => null,
  };
  return family == null ? null : '/etc/ssh/ssh_host_${family}_key.pub';
}

/// Trust-on-first-use, made explicit.
///
/// Shows the algorithm and the OpenSSH-style `SHA256:` fingerprint — the two
/// things the user needs to compare against what the server operator published —
/// and refuses to enable the accept button until they confirm they have done
/// that comparison. Trust on first use is fine; a dialog whose default action
/// trusts a stranger is not, so the safe action is the one that has focus and
/// the trusting action starts disabled.
///
/// Returns `true` only for a deliberate accept. Cancelling, or dismissing,
/// returns `false`.
class HostKeyTrustDialog extends StatefulWidget {
  const HostKeyTrustDialog({required this.presentation, super.key});

  final HostKeyPresentation presentation;

  static Future<bool> show(
    BuildContext context,
    HostKeyPresentation presentation,
  ) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => HostKeyTrustDialog(presentation: presentation),
      ) ??
      false;

  @override
  State<HostKeyTrustDialog> createState() => _HostKeyTrustDialogState();
}

class _HostKeyTrustDialogState extends State<HostKeyTrustDialog> {
  bool _compared = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.presentation;
    final publicKeyFile = hostKeyPublicKeyFile(p.keyType);

    return AlertDialog(
      icon: Icon(AppIcons.warningCircle, color: theme.colorScheme.tertiary),
      title: const Text('Unrecognised host key'),
      // Scrollable: the fingerprint and the comparison instructions must stay
      // reachable on a short window, and a clipped fingerprint is a fingerprint
      // nobody checks.
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The authenticity of ${p.host}:${p.port} cannot be established. '
                'Chitragupta has never connected to it before.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: Insets.lg),
              _KeyFacts(keyType: p.keyType, fingerprint: p.fingerprint),
              const SizedBox(height: Insets.lg),
              Text(
                publicKeyFile == null
                    ? 'Compare this fingerprint with the one published for this '
                          'host before accepting it.'
                    : 'Compare it with the one the server publishes. On the host '
                          'itself:',
                style: theme.textTheme.bodySmall,
              ),
              if (publicKeyFile != null) ...[
                const SizedBox(height: Insets.xs),
                SelectableText(
                  'ssh-keygen -lf $publicKeyFile',
                  style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12),
                ),
              ],
              const SizedBox(height: Insets.sm),
              Text(
                'If the fingerprints differ, someone may be impersonating this '
                'host. Accepting pins this key: a different one later is refused '
                'outright.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.sm),
              CheckboxListTile(
                value: _compared,
                onChanged: (v) => setState(() => _compared = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  'I have compared this fingerprint and it matches',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        // The safe action holds focus, so Enter or a stray space refuses.
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _compared ? () => Navigator.of(context).pop(true) : null,
          icon: const Icon(AppIcons.check, size: 16),
          label: const Text('Trust this key'),
        ),
      ],
    );
  }
}

/// Algorithm and fingerprint, laid out so both are readable and copyable —
/// these are the two values the whole decision rests on.
class _KeyFacts extends StatelessWidget {
  const _KeyFacts({required this.keyType, required this.fingerprint});

  final String keyType;
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Key algorithm', style: theme.textTheme.labelSmall),
          SelectableText(
            keyType,
            style: const TextStyle(fontFamily: kMonoFamily, fontSize: 13),
          ),
          const SizedBox(height: Insets.sm),
          Text('Fingerprint', style: theme.textTheme.labelSmall),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  fingerprint,
                  style: const TextStyle(fontFamily: kMonoFamily, fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Copy fingerprint',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.copySimple, size: 16),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: fingerprint)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
