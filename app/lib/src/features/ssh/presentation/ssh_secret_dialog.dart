import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// Asks for a password or a passphrase, for one connection. There is no
/// "remember this": what is typed reaches `dartssh2` and nothing else.
class SshSecretDialog extends StatefulWidget {
  const SshSecretDialog({
    required this.hostName,
    required this.address,
    required this.passphrase,
    super.key,
  });

  /// The saved host's name and `user@host:port` — the server's question
  /// carries both, for a host it may be testing before it is saved.
  final String hostName;
  final String address;
  final bool passphrase;

  /// Returns the secret, or `null` if the user cancelled.
  static Future<String?> show(
    BuildContext context, {
    required String hostName,
    required String address,
    required bool passphrase,
  }) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        SshSecretDialog(hostName: hostName, address: address, passphrase: passphrase),
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
    final isPassphrase = widget.passphrase;

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
                  ? 'The private key for ${widget.hostName} is encrypted. '
                        'Enter its passphrase to connect to '
                        '${widget.address}.'
                  : 'Enter the password for ${widget.address}.',
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
                  icon: Icon(_visible ? AppIcons.xCircle : AppIcons.circle),
                  onPressed: () => setState(() => _visible = !_visible),
                ),
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Used for this connection only. Karmashala does not store '
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
