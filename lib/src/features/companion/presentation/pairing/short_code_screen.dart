import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/design_tokens.dart';
import '../../client/companion_gateway.dart';

/// The QR fallback: paste the pairing code copied from the desktop.
class ShortCodeScreen extends ConsumerStatefulWidget {
  const ShortCodeScreen({super.key});

  @override
  ConsumerState<ShortCodeScreen> createState() => _ShortCodeScreenState();
}

class _ShortCodeScreenState extends ConsumerState<ShortCodeScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final code = _code.text.trim();
    if (_busy || code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(companionGatewayProvider).pairWithCode(code);
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Type the pairing code')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'On the desktop\'s pairing dialog, press "Copy pairing '
                'code" and paste it here. Codes expire after five minutes.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.lg),
              TextField(
                controller: _code,
                autofocus: true,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _pair(),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                ),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'Paste the pairing code',
                  counterText: '',
                  errorText: _error,
                  errorMaxLines: 4,
                ),
              ),
              const SizedBox(height: Insets.lg),
              FilledButton(
                onPressed: _busy ? null : _pair,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Pair'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
