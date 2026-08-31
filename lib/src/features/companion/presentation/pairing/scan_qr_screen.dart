import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../app/theme/design_tokens.dart';
import '../../client/companion_gateway.dart';
import '../../client/pairing_input.dart';
import 'pairing_progress_screen.dart';
import 'short_code_screen.dart';

/// Scans the pairing QR code the desktop displays.
///
/// The camera preview is injectable ([scannerBuilder]) so widget tests can
/// drive the payload path without a camera or the scanner's platform channel.
class ScanQrScreen extends ConsumerStatefulWidget {
  const ScanQrScreen({this.scannerBuilder, super.key});

  /// Builds the viewfinder. Defaults to a live [MobileScanner]; tests inject a
  /// stand-in and call the handed-in callback with a scanned payload.
  final Widget Function(BuildContext context, ValueChanged<String> onPayload)?
  scannerBuilder;

  @override
  ConsumerState<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends ConsumerState<ScanQrScreen> {
  bool _busy = false;
  String? _error;
  String? _refused;

  Future<void> _onPayload(String payload) async {
    // One attempt at a time, and never the same refused payload again — a
    // camera re-reads the same code many times a second.
    if (_busy || payload == _refused) return;
    if (classifyPairingInput(payload) != PairingInputKind.unrecognised) {
      // A real code: leave the camera and narrate the attempt. Marked refused
      // so coming Back does not immediately re-push over the same frame.
      setState(() {
        _refused = payload;
        _error = null;
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PairingProgressScreen(
            attempt: (gateway) => gateway.pairWithQr(payload),
          ),
        ),
      );
      return;
    }
    // Not a pairing code at all: refuse inline and keep scanning.
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(companionGatewayProvider).pairWithQr(payload);
      if (!mounted) return;
      // The shell swaps to the tabs the moment the pairing stream says so.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on PairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _refused = payload;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _refused = payload;
        _error = '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _scanner(BuildContext context) {
    final builder = widget.scannerBuilder;
    if (builder != null) return builder(context, _onPayload);
    return MobileScanner(
      onDetect: (capture) {
        final barcodes = capture.barcodes;
        final raw = barcodes.isEmpty ? null : barcodes.first.rawValue;
        if (raw != null && raw.isNotEmpty) _onPayload(raw);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the QR code')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _scanner(context)),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.md,
                  Insets.sm,
                  Insets.md,
                  0,
                ),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: Text(
                "Point the camera at the QR code in the desktop's "
                'Remote access settings.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: TextButton(
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => const ShortCodeScreen(),
                  ),
                ),
                child: const Text('Type the code instead'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
