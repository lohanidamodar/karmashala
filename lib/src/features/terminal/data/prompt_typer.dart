import 'dart:async';

/// [text] as something that can be typed and never run: one line, no control
/// bytes. A carriage return is "submit" to a PTY, and an escape could be one.
String unsubmittable(String text) => text
    .replaceAll(RegExp(r'[\r\n]+'), ' ')
    .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
    .trim();

/// Types a command at a pane's prompt and leaves it for the person to run. A
/// new pane drops what is typed before it connects, so the text waits for the
/// shell's first output and then a quiet spell, which a banner restarts.
class PromptTyper {
  PromptTyper({
    required this.send,
    this.settle = const Duration(milliseconds: 400),
  });

  final void Function(String text) send;
  final Duration settle;

  String? _pending;
  Timer? _quiet;
  var _seenOutput = false;
  var _disposed = false;

  void type(String text) {
    if (_disposed) return;
    final line = unsubmittable(text);
    if (line.isEmpty) return;
    _pending = line;
    if (_seenOutput) _arm();
  }

  /// The pane's process said something.
  void onOutput() {
    if (_disposed) return;
    _seenOutput = true;
    if (_pending != null) _arm();
  }

  void _arm() {
    _quiet?.cancel();
    _quiet = Timer(settle, () {
      final line = _pending;
      _pending = null;
      if (line != null && !_disposed) send(line);
    });
  }

  void dispose() {
    _disposed = true;
    _quiet?.cancel();
    _pending = null;
  }
}
