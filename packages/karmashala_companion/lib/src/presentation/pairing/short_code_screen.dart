import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/companion.dart';
import '../../application/companion_providers.dart';
import '../companion_chrome.dart';
import 'pairing_progress_screen.dart';

/// The QR fallback: type the code shown under the desktop's QR, or paste the
/// full pairing payload — both are sniffed apart by the gateway.
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
    if (classifyPairingInput(code) != PairingInputKind.unrecognised) {
      // A real code or payload: leave the input and narrate the attempt.
      setState(() => _error = null);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PairingProgressScreen(
            attempt: (gateway) => gateway.pairWithCode(code),
          ),
        ),
      );
      return;
    }
    // Not code-shaped: let the gateway refuse it in words, inline.
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
      appBar: companionAppBar(
        context,
        title: const Text('Type the pairing code'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "Type the code shown under the desktop's QR "
                '(like K7QM-3X2W-…), or paste its full pairing payload. '
                'Codes expire after five minutes.',
                // Body, not caption: a paragraph someone reads before typing.
                style: theme.textTheme.bodyMedium?.copyWith(
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
                // Read character by character, so it takes the ramp's largest
                // body step.
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontFamily: kMonoFamily,
                ),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'Type or paste the pairing code',
                  counterText: '',
                  errorText: _error,
                  errorMaxLines: 4,
                ),
              ),
              const SizedBox(height: Insets.lg),
              FilledButton(
                onPressed: _busy ? null : _pair,
                child: _busy
                    ? const SizedBox.square(
                        dimension: Touch.icon,
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
