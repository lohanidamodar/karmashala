import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';

/// The terminal font size a touch device keeps for itself (Stage 2 step 9),
/// in a file of its own. `Settings.terminalFontSize` is kept at the server, so
/// a pinch there would resize every desktop's panes. Null until set: the
/// shared size is used.
class DeviceTerminalFontSize extends Notifier<double?> {
  /// Below the shared setting's floor, so a 120-column session fits a phone.
  static const min = 5.0;
  static const max = 28.0;

  static final _log = AppLogger.named('terminal.font');
  Timer? _save;

  @override
  double? build() {
    ref.onDispose(() => _save?.cancel());
    unawaited(_load());
    return null;
  }

  Future<File> _file() async =>
      File(p.join((await appSupportDirectory()).path, 'terminal_device.json'));

  Future<void> _load() async {
    try {
      final decoded = jsonDecode(await (await _file()).readAsString());
      final size = decoded is Map ? decoded['fontSize'] : null;
      if (size is num && ref.mounted && state == null) {
        state = size.toDouble().clamp(min, max);
      }
    } on Object {
      // Nothing kept yet, or unreadable: the shared size stands.
    }
  }

  void set(double size) {
    state = size.clamp(min, max);
    _save?.cancel();
    // A pinch sets it every frame; the file is written once it settles.
    _save = Timer(const Duration(milliseconds: 600), _write);
  }

  Future<void> _write() async {
    final size = state;
    if (size == null) return;
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'fontSize': size}), flush: true);
    } on Object catch (e) {
      _log.warning('Keeping the terminal font size failed: $e');
    }
  }
}

final deviceTerminalFontSizeProvider =
    NotifierProvider<DeviceTerminalFontSize, double?>(
      DeviceTerminalFontSize.new,
    );
