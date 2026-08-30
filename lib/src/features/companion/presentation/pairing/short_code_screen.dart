import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/design_tokens.dart';
import '../../client/companion_gateway.dart';

/// The QR fallback: type the 8-character code the desktop shows.
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
                'The desktop shows an 8-character code beside its QR code. '
                'Codes expire after five minutes.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.lg),
              TextField(
                controller: _code,
                autofocus: true,
                enabled: !_busy,
                maxLength: 8,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _pair(),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: kMonoFamily,
                  letterSpacing: 4,
                ),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'ABCD1234',
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
