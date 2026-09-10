import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:karmashala_core/logging.dart';

/// The newest decoded frame of a simulator's screen. Stands in for a player:
/// libmpv has no `mpjpeg` demuxer, and decoding is drop-to-latest.
class SimulatorFrames {
  SimulatorFrames(Stream<Uint8List> frames) {
    _subscription = frames.listen(
      _onFrame,
      onError: (Object error) {
        _logger.warning('The picture stream stopped reason=$error');
        if (!_errors.isClosed) _errors.add('$error');
      },
    );
  }

  /// Repainted on every decoded frame. Never holds a disposed image.
  final ValueNotifier<ui.Image?> image = ValueNotifier<ui.Image?>(null);

  /// Reported so a stream that dies is visible rather than a frozen picture.
  Stream<String> get errors => _errors.stream;

  final StreamController<String> _errors = StreamController<String>.broadcast();
  late final StreamSubscription<Uint8List> _subscription;
  AppLogger get _logger => AppLogger.named('simulator-live');

  Uint8List? _pending;
  bool _decoding = false;
  bool _disposed = false;
  bool _reportedFirstFrame = false;

  void _onFrame(Uint8List jpeg) {
    _pending = jpeg;
    if (!_decoding) unawaited(_drain());
  }

  Future<void> _drain() async {
    _decoding = true;
    try {
      while (!_disposed) {
        final bytes = _pending;
        if (bytes == null) return;
        _pending = null;
        final ui.Image decoded;
        try {
          final codec = await ui.instantiateImageCodec(bytes);
          decoded = (await codec.getNextFrame()).image;
          codec.dispose();
        } on Object catch (error) {
          // A truncated or torn frame is not worth ending the picture over —
          // the next one is milliseconds away.
          _logger.debug('Skipped an undecodable frame reason=$error');
          continue;
        }
        if (_disposed) {
          decoded.dispose();
          return;
        }
        if (!_reportedFirstFrame) {
          _reportedFirstFrame = true;
          // Once, on the first frame: the difference between "the picture is
          // live" and "the pane is black" is otherwise invisible in the log.
          _logger.info(
            'Live picture started at ${decoded.width}x${decoded.height}.',
          );
        }
        final previous = image.value;
        image.value = decoded;
        // Only once it is no longer the value: disposing an image that is still
        // being painted tears the frame.
        previous?.dispose();
      }
    } finally {
      _decoding = false;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await _errors.close();
    image.value?.dispose();
    image.value = null;
    image.dispose();
  }
}
