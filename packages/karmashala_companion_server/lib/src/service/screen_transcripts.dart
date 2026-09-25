import 'package:karmashala_remote/remote.dart';

/// A session's screens as the transcript a phone reads while no desktop app is
/// connected: the host has no agent's own record to read, only what its PTY
/// drew. Each distinct screen it was asked for becomes one message, oldest
/// first, so the append-only transcript wire carries a live view: a phone
/// polling a working session is sent the screen as it is now.
///
/// **Throttled**, because a spinner redraws every frame: a new screen is kept
/// at most every [minInterval], and a history past [maxScreens] starts again
/// from the screen now — the phone's cursor then resets, which it survives.
class ScreenTranscripts {
  ScreenTranscripts({
    this.minInterval = const Duration(seconds: 5),
    this.maxScreens = 200,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Duration minInterval;
  final int maxScreens;
  final DateTime Function() _now;
  final Map<String, _Screens> _bySession = {};

  /// The transcript of [sessionId] with [screen] taken into account. A null
  /// screen is a session this host cannot show, and the page says there is no
  /// chat view for it rather than handing over an empty one.
  RemoteTranscriptPage read(String sessionId, String? screen) {
    if (screen == null) {
      return RemoteTranscriptPage(
        sessionId: sessionId,
        messages: const [],
        cursor: 0,
        absence: RemoteTranscriptAbsence.noChatView,
      );
    }
    final screens = _bySession.putIfAbsent(sessionId, _Screens.new);
    final now = _now();
    final text = screen.trimRight();
    final last = screens.at;
    if (text.isNotEmpty &&
        text != screens.lastText &&
        (last == null || now.difference(last) >= minInterval)) {
      if (screens.texts.length >= maxScreens) screens.texts.clear();
      screens.texts.add(text);
      screens.at = now;
    }
    return RemoteTranscriptPage(
      sessionId: sessionId,
      messages: [
        for (final text in screens.texts)
          RemoteTranscriptMessage(role: 'agent', text: text),
      ],
      cursor: screens.texts.length,
    );
  }

  /// Forgets [sessionId]: the host no longer holds it.
  void forget(String sessionId) => _bySession.remove(sessionId);
}

class _Screens {
  final List<String> texts = [];
  DateTime? at;

  String? get lastText => texts.isEmpty ? null : texts.last;
}
