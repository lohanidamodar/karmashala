import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Why there is no viewfinder to show.
enum ScannerFailure {
  /// The person said no, or the OS did on their behalf.
  permissionDenied,

  /// Nothing here can scan: no camera, or a platform the plugin does not run on.
  noCamera,

  /// The camera exists and would not start.
  failed,
}

/// What the torch can do right now. [unavailable] hides the button: a control
/// for a light the device does not have is a button that does nothing.
enum ScannerTorch { unavailable, off, on }

/// A camera the scan screen can drive without knowing whose it is — the real
/// one on a phone, a scripted one in a widget test.
abstract interface class PairingScanner {
  ValueListenable<ScannerTorch> get torch;

  Future<void> toggleTorch();

  /// The viewfinder. [paused] stops the camera while another route covers it.
  Widget build(
    BuildContext context, {
    required ValueChanged<String> onPayload,
    required ValueChanged<ScannerFailure> onFailure,
    required bool paused,
  });

  void dispose();
}

/// Whether `mobile_scanner` has an implementation where this is running. It
/// ships none for Windows or Linux, where the companion also runs (the desktop
/// build's companion mode), and asking it there is a `MissingPluginException`.
bool get platformCanScan =>
    kIsWeb ||
    switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.fuchsia => false,
    };

/// The device's camera, through `mobile_scanner`.
class CameraPairingScanner implements PairingScanner {
  CameraPairingScanner()
    : _controller = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
      ) {
    _controller.addListener(_readTorch);
  }

  final MobileScannerController _controller;
  final _torch = ValueNotifier<ScannerTorch>(ScannerTorch.unavailable);

  void _readTorch() => _torch.value = switch (_controller.value.torchState) {
    TorchState.unavailable => ScannerTorch.unavailable,
    TorchState.on => ScannerTorch.on,
    TorchState.off || TorchState.auto => ScannerTorch.off,
  };

  @override
  ValueListenable<ScannerTorch> get torch => _torch;

  @override
  Future<void> toggleTorch() => _controller.toggleTorch();

  @override
  Widget build(
    BuildContext context, {
    required ValueChanged<String> onPayload,
    required ValueChanged<ScannerFailure> onFailure,
    required bool paused,
  }) => _CameraView(
    controller: _controller,
    onPayload: onPayload,
    onFailure: onFailure,
    paused: paused,
  );

  @override
  void dispose() {
    _controller.removeListener(_readTorch);
    unawaited(_controller.dispose());
    _torch.dispose();
  }
}

class _CameraView extends StatefulWidget {
  const _CameraView({
    required this.controller,
    required this.onPayload,
    required this.onFailure,
    required this.paused,
  });

  final MobileScannerController controller;
  final ValueChanged<String> onPayload;
  final ValueChanged<ScannerFailure> onFailure;
  final bool paused;

  @override
  State<_CameraView> createState() => _CameraViewState();
}

/// `MobileScanner` only watches the app lifecycle for a controller it made
/// itself, so with ours the camera would stay on behind a backgrounded app.
class _CameraViewState extends State<_CameraView> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(_CameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paused != widget.paused) _run(!widget.paused);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A start before permission was answered would ask for it a second time.
    if (!widget.controller.value.hasCameraPermission) return;
    _run(state == AppLifecycleState.resumed && !widget.paused);
  }

  void _run(bool on) {
    unawaited(() async {
      try {
        await (on ? widget.controller.start() : widget.controller.stop());
      } on MobileScannerException {
        // Already in the state asked for, or disposed under us. The error
        // builder reports the failures a person can do something about.
      }
    }());
  }

  static ScannerFailure? _failureFor(MobileScannerErrorCode code) =>
      switch (code) {
        MobileScannerErrorCode.permissionDenied =>
          ScannerFailure.permissionDenied,
        MobileScannerErrorCode.unsupported => ScannerFailure.noCamera,
        MobileScannerErrorCode.genericError => ScannerFailure.failed,
        // The controller's own bookkeeping, not a camera anybody is missing.
        _ => null,
      };

  @override
  Widget build(BuildContext context) => MobileScanner(
    controller: widget.controller,
    onDetect: (capture) {
      final barcodes = capture.barcodes;
      final raw = barcodes.isEmpty ? null : barcodes.first.rawValue;
      if (raw != null && raw.isNotEmpty) widget.onPayload(raw);
    },
    errorBuilder: (context, error) {
      final failure = _failureFor(error.errorCode);
      if (failure != null) {
        // Reported after this frame: the screen answers by rebuilding.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onFailure(failure),
        );
      }
      return const ColoredBox(color: Colors.black, child: SizedBox.expand());
    },
  );
}
