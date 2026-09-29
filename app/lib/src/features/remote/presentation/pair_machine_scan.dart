import 'dart:async';

import 'package:flutter/material.dart';
import 'package:karmashala_companion/pairing.dart'
    show
        CameraPairingScanner,
        PairingScanner,
        ScannerFailure,
        ScannerTorch,
        platformCanScan;
import 'package:karmashala_remote/companion.dart'
    show PairingInputKind, classifyPairingInput;
import 'package:karmashala_remote/pairing.dart'
    show
        HostInviteExpiredException,
        HostInviteTooNewException,
        HostPairingInvite;
import 'package:karmashala_remote/remote.dart' show ProtocolException;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import 'pair_machine_forms.dart';
import 'pair_machine_page.dart';

/// Scans a machine's pairing QR with the companion's [PairingScanner]: a
/// server's `karmashala_host pair` invite, or a desktop's "Pair a phone".
class PairMachineScanScreen extends StatefulWidget {
  const PairMachineScanScreen({super.key, required this.pairer, this.scanner});

  final MachinePairer pairer;

  /// The camera; the device's own where one can be asked for.
  final PairingScanner? scanner;

  @override
  State<PairMachineScanScreen> createState() => _PairMachineScanScreenState();
}

class _PairMachineScanScreenState extends State<PairMachineScanScreen> {
  late final PairingScanner? _scanner;
  late final bool _ownsScanner;
  ScannerFailure? _failure;
  var _busy = false;
  String? _error;

  /// The last payload refused: a camera reads the same code many times a
  /// second, and one refusal is enough.
  String? _refused;

  @override
  void initState() {
    super.initState();
    _ownsScanner = widget.scanner == null;
    _scanner =
        widget.scanner ?? (platformCanScan ? CameraPairingScanner() : null);
    if (_scanner == null) _failure = ScannerFailure.noCamera;
  }

  @override
  void dispose() {
    if (_ownsScanner) _scanner?.dispose();
    super.dispose();
  }

  void _onFailure(ScannerFailure failure) {
    if (mounted && _failure != failure) setState(() => _failure = failure);
  }

  /// Why [payload] is refused before anything is dialled, or null.
  static String? _refusal(String payload) {
    if (HostPairingInvite.looksLike(payload)) {
      try {
        HostPairingInvite.decode(payload);
        return null;
      } on HostInviteExpiredException catch (error) {
        return error.message;
      } on HostInviteTooNewException {
        return 'This code was made by a newer Karmashala. Update this app, '
            'then scan it again.';
      } on ProtocolException {
        return 'That is not a Karmashala pairing code.';
      }
    }
    return classifyPairingInput(payload) == PairingInputKind.unrecognised
        ? 'That is not a Karmashala pairing code.'
        : null;
  }

  Future<void> _onPayload(String payload) async {
    if (_busy || payload == _refused) return;
    final refused = _refusal(payload);
    if (refused != null) {
      setState(() {
        _refused = payload;
        _error = refused;
      });
      return;
    }
    setState(() {
      _busy = true;
      _refused = payload;
      _error = null;
    });
    final refusal = await widget.pairer.pair(code: payload);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = refusal;
    });
  }

  void _typeInstead({required bool byAddress}) => unawaited(
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) =>
            PairMachineCodeScreen(pairer: widget.pairer, byAddress: byAddress),
      ),
    ),
  );

  Widget _fallback(ThemeData theme, ScannerFailure failure) {
    final (title, body) = switch (failure) {
      ScannerFailure.permissionDenied => (
        'Camera access is off',
        "Scanning needs the camera. Allow it for Karmashala in the phone's "
            'settings and come back, or pair without it.',
      ),
      ScannerFailure.noCamera => (
        'No camera to scan with',
        'This device has no camera Karmashala can use. Pair without one.',
      ),
      ScannerFailure.failed => (
        'The camera would not start',
        'Something else may be using it. Close it and come back, or pair '
            'without the camera.',
      ),
    };
    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Icon(AppIcons.camera, size: 40, color: theme.colorScheme.outline),
        const SizedBox(height: Insets.md),
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: Insets.sm),
        Text(body, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Insets.lg),
        FilledButton(
          onPressed: () => _typeInstead(byAddress: false),
          child: const Text('Paste the code instead'),
        ),
        const SizedBox(height: Insets.sm),
        OutlinedButton(
          onPressed: () => _typeInstead(byAddress: true),
          child: const Text('Add a machine by address'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scanner = _scanner;
    final failure = _failure;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan the QR code'),
        actions: [
          if (scanner != null && failure == null) _TorchButton(scanner),
        ],
      ),
      body: SafeArea(
        child: scanner == null || failure != null
            ? _fallback(theme, failure ?? ScannerFailure.noCamera)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: scanner.build(
                      context,
                      onPayload: (payload) => unawaited(_onPayload(payload)),
                      onFailure: _onFailure,
                      paused: _busy,
                    ),
                  ),
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  // The words scroll in their share, so no error or text
                  // scale shrinks the viewfinder to nothing.
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(Insets.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_error != null) ...[
                            Text(
                              _error!,
                              key: const Key('pair-machine-scan-error'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                            const SizedBox(height: Insets.sm),
                          ],
                          Text(
                            _busy
                                ? 'Pairing…'
                                : 'Point the camera at the QR code the '
                                      'machine shows for pairing.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _typeInstead(byAddress: false),
                            child: const Text('Type the code instead'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The torch, shown only while the device says it has one.
class _TorchButton extends StatelessWidget {
  const _TorchButton(this.scanner);

  final PairingScanner scanner;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ScannerTorch>(
    valueListenable: scanner.torch,
    builder: (context, torch, _) {
      if (torch == ScannerTorch.unavailable) return const SizedBox.shrink();
      final on = torch == ScannerTorch.on;
      return IconButton(
        tooltip: on ? 'Turn the torch off' : 'Turn the torch on',
        isSelected: on,
        icon: const Icon(AppIcons.sun),
        onPressed: scanner.toggleTorch,
      );
    },
  );
}
