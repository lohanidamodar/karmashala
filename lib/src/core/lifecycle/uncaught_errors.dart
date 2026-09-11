import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:karmashala_core/logging.dart';

/// Routes errors nothing caught into the log. Without it a release build drops
/// them: no console, no file, no buffer — the failure simply never happened.
class UncaughtErrorHandlers {
  UncaughtErrorHandlers(this._logger, {this.repeatBound = 20});

  final AppLogger _logger;

  /// Identical messages past this are counted, not written — a build error
  /// re-thrown every frame must not fill the file.
  final int repeatBound;

  final Map<String, int> _seen = {};
  int _suppressed = 0;

  /// Lines withheld by [repeatBound].
  int get suppressed => _suppressed;

  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;

  void install() {
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    FlutterError.onError = (details) {
      final context = details.context?.toDescription();
      record(
        context == null ? 'Flutter error' : 'Flutter error ($context)',
        details.exception,
        details.stack,
      );
      if (kDebugMode) _previousFlutter?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record('Uncaught error', error, stack);
      return true;
    };
  }

  void uninstall() {
    FlutterError.onError = _previousFlutter;
    PlatformDispatcher.instance.onError = _previousPlatform;
  }

  /// Returns whether the entry was written.
  bool record(String what, Object error, StackTrace? stack) {
    final key = '$what: $error';
    final count = (_seen[key] ?? 0) + 1;
    _seen[key] = count;
    if (count > repeatBound) {
      _suppressed++;
      return false;
    }
    _logger.error(
      count == repeatBound ? '$what (further repeats withheld)' : what,
      error,
      stack,
    );
    return true;
  }
}
