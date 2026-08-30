import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/ssh_prompt_controller.dart';
import '../domain/ssh_host.dart';

/// Asks for a password or a private key passphrase, for one connection.
///
/// There is no "remember this" checkbox and there never will be: `ssh_hosts`
/// has no column that could hold a credential, and a test asserts it. What is
/// typed here reaches `dartssh2` and nothing else.
class SshSecretDialog extends StatefulWidget {
  const SshSecretDialog({required this.host, required this.kind, super.key});

  final SshHost host;
  final SshSecretKind kind;

  /// Returns the secret, or `null` if the user cancelled.
  static Future<String?> show(
    BuildContext context, {
    required SshHost host,
    required SshSecretKind kind,
  }) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SshSecretDialog(host: host, kind: kind),
  );

  @override
  State<SshSecretDialog> createState() => _SshSecretDialogState();
}

class _SshSecretDialogState extends State<SshSecretDialog> {
  final _controller = TextEditingController();
  bool _visible = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text;
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPassphrase = widget.kind == SshSecretKind.passphrase;

    return AlertDialog(
      icon: Icon(AppIcons.linkSimple, color: theme.colorScheme.tertiary),
      title: Text(
        isPassphrase ? 'Private key passphrase' : 'Password required',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isPassphrase
                  ? 'The private key for ${widget.host.name} is encrypted. '
                        'Enter its passphrase to connect to '
                        '${widget.host.address}.'
                  : 'Enter the password for ${widget.host.address}.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Insets.lg),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: !_visible,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: isPassphrase ? 'Passphrase' : 'Password',
                suffixIcon: IconButton(
                  tooltip: _visible ? 'Hide' : 'Show',
                  icon: Icon(
                    _visible ? AppIcons.xCircle : AppIcons.circle,
                    size: 16,
                  ),
                  onPressed: () => setState(() => _visible = !_visible),
                ),
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Used for this connection only. Chitragupta does not store '
              'passwords or passphrases.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Connect')),
      ],
    );
  }
}
