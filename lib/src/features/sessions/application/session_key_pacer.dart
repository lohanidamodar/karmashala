import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import 'session_launcher.dart';

/// Types an answer into a session's pane the way a person would: one keystroke
/// at a time, and a longer pause after Enter, which draws the next screen. One
/// burst loses the keys that land while a question's next tab draws
/// (docs/SETTLED.md).
class SessionKeyPacer {
  SessionKeyPacer({
    required this.press,
    this.afterKey = const Duration(milliseconds: 150),
    this.afterEnter = const Duration(milliseconds: 700),
    Future<void> Function(Duration)? wait,
  }) : _wait = wait ?? ((d) => Future<void>.delayed(d));

  /// Presses keys in the session's pane; false without one.
  final bool Function(String sessionId, String keys) press;

  final Duration afterKey;
  final Duration afterEnter;
  final Future<void> Function(Duration) _wait;

  /// False when the pane was gone before the first key; keys already typed
  /// are not taken back.
  Future<bool> type(String sessionId, String keys) async {
    final strokes = keystrokesOf(keys);
    if (strokes.isEmpty) return false;
    for (final stroke in strokes) {
      if (!press(sessionId, stroke)) return false;
      await _wait(stroke == '\r' ? afterEnter : afterKey);
    }
    return true;
  }
}

final sessionKeyPacerProvider = Provider<SessionKeyPacer>(
  (ref) => SessionKeyPacer(
    press: (sessionId, keys) =>
        ref.read(sessionLauncherProvider).pressKeys(sessionId, keys),
  ),
);
