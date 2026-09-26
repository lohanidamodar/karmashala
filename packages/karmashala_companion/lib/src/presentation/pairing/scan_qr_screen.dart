import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/pairing.dart'
    show
        HostInviteExpiredException,
        HostInviteTooNewException,
        HostPairingInvite;
import 'package:karmashala_remote/remote.dart' show ProtocolException;
import '../../application/companion_providers.dart';
import '../../application/companion_runtime.dart';
import '../companion_chrome.dart';
import '../companion_route.dart';
import '../companion_states.dart';
import 'add_machine_screen.dart';
import 'pairing_progress_screen.dart';
import 'pairing_scanner.dart';
import 'short_code_screen.dart';

/// Scans a pairing QR — the desktop app's own, the one it shows for a server,
/// or the one a server's `karmashala_host pair` prints.
/// The camera is a [PairingScanner], so a widget test needs no camera or
/// platform channel.
class ScanQrScreen extends ConsumerStatefulWidget {
  const ScanQrScreen({this.scannerBuilder, this.scanner, super.key});

  /// A bare viewfinder: tests inject a stand-in and call the handed-in callback
  /// with a scanned payload. It has no torch and never fails; [scanner] is the
  /// seam for those.
  final Widget Function(BuildContext context, ValueChanged<String> onPayload)?
  scannerBuilder;

  /// The camera. Defaults to the device's, where there is one to ask for.
  final PairingScanner? scanner;

  @override
  ConsumerState<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends ConsumerState<ScanQrScreen> {
  bool _busy = false;
  String? _error;
  String? _refused;

  /// True while the progress route covers this one: the camera is stopped
  /// rather than left reading a QR nobody is looking through.
  bool _covered = false;

  ScannerFailure? _failure;

  /// Null where nothing can scan, which the fallback says instead of throwing.
  late final PairingScanner? _scanner;
  late final bool _ownsScanner;

  @override
  void initState() {
    super.initState();
    final builder = widget.scannerBuilder;
    _ownsScanner = widget.scanner == null;
    _scanner =
        widget.scanner ??
        (builder != null
            ? _BuilderScanner(builder)
            : platformCanScan
            ? CameraPairingScanner()
            : null);
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

  /// What is wrong with a machine's invite that no dial would fix, or null.
  /// Said here so an expired code keeps the camera up for the fresh one,
  /// instead of spending a pairing screen on it.
  String? _inviteRefusal(String payload) {
    try {
      HostPairingInvite.decode(
        payload,
        now: ref.read(companionClockProvider).nowUtc(),
      );
      return null;
    } on HostInviteExpiredException catch (error) {
      return error.message;
    } on HostInviteTooNewException {
      return 'This code was made by a newer Karmashala. Update this app, then '
          'scan it again.';
    } on ProtocolException {
      return 'That is not a Karmashala pairing code.';
    }
  }

  Future<void> _onPayload(String payload) async {
    // One attempt at a time, and never the same refused payload again — a
    // camera re-reads the same code many times a second.
    if (_busy || _covered || payload == _refused) return;
    final isInvite = HostPairingInvite.looksLike(payload);
    if (isInvite) {
      final refusal = _inviteRefusal(payload);
      if (refusal != null) {
        setState(() {
          _refused = payload;
          _error = refusal;
        });
        return;
      }
    }
    if (classifyPairingInput(payload) != PairingInputKind.unrecognised) {
      // A real code: leave the camera and narrate the attempt. Marked refused
      // so coming Back does not immediately re-push over the same frame.
      setState(() {
        _refused = payload;
        _error = null;
        _covered = true;
      });
      await Navigator.of(context).push(
        companionRoute<void>(
          context,
          (_) => PairingProgressScreen(
            aimed: isInvite,
            attempt: (gateway) => gateway.pairWithQr(payload),
          ),
        ),
      );
      if (mounted) setState(() => _covered = false);
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

  void _pasteInstead() => Navigator.of(context).pushReplacement(
    companionRoute<void>(context, (_) => const ShortCodeScreen()),
  );

  void _addByAddress() => Navigator.of(context).pushReplacement(
    companionRoute<void>(context, (_) => const AddMachineScreen()),
  );

  /// No viewfinder: why, and the two ways in that need no camera.
  Widget _fallback(ScannerFailure failure) {
    final (title, body) = switch (failure) {
      ScannerFailure.permissionDenied => (
        'Camera access is off',
        'Scanning needs the camera, and this phone has not allowed it. Allow '
            "camera access for Karmashala in the phone's settings and come "
            'back — or pair without it.',
      ),
      ScannerFailure.noCamera => (
        'No camera to scan with',
        'This device has no camera Karmashala can use. Pair without one.',
      ),
      ScannerFailure.failed => (
        'The camera would not start',
        'Something else may be using it. Close it and come back — or pair '
            'without the camera.',
      ),
    };
    return CompanionNotice(
      icon: AppIcons.camera,
      title: title,
      body: body,
      actionLabel: 'Paste the code instead',
      onAction: _pasteInstead,
      secondaryLabel: 'Add a machine by address',
      onSecondary: _addByAddress,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scanner = _scanner;
    final failure = _failure;
    if (scanner == null || failure != null) {
      return Scaffold(
        appBar: companionAppBar(context, title: const Text('Scan the QR code')),
        body: SafeArea(child: _fallback(failure ?? ScannerFailure.noCamera)),
      );
    }
    return Scaffold(
      appBar: companionAppBar(
        context,
        title: const Text('Scan the QR code'),
        actions: [_TorchButton(scanner)],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          // The words under the camera scroll within the other half, so no
          // error or text scale can shrink the viewfinder to nothing.
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: scanner.build(
                  context,
                  onPayload: _onPayload,
                  onFailure: _onFailure,
                  paused: _covered,
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * (1 - _cameraShare),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Insets.lg,
                            Insets.sm,
                            Insets.lg,
                            0,
                          ),
                          child: CompanionInlineError(_error!),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(Insets.lg),
                        child: Text(
                          'Point the camera at the QR code a machine shows '
                          "for pairing: the desktop app's Remote access "
                          'settings or "Pair a phone" dialog, or '
                          'karmashala_host pair on a server.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: Insets.sm),
                        child: TextButton(
                          onPressed: _pasteInstead,
                          child: const Text('Type the code instead'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The least of the body the viewfinder keeps.
  static const _cameraShare = 0.5;
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

/// The bare-viewfinder seam as a [PairingScanner]: no torch, never fails.
class _BuilderScanner implements PairingScanner {
  _BuilderScanner(this._builder);

  final Widget Function(BuildContext context, ValueChanged<String> onPayload)
  _builder;

  @override
  final ValueListenable<ScannerTorch> torch = ValueNotifier(
    ScannerTorch.unavailable,
  );

  @override
  Future<void> toggleTorch() async {}

  @override
  Widget build(
    BuildContext context, {
    required ValueChanged<String> onPayload,
    required ValueChanged<ScannerFailure> onFailure,
    required bool paused,
  }) => _builder(context, onPayload);

  @override
  void dispose() {}
}
