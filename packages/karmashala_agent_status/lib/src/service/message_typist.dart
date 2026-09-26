import '../domain/prompt_refusal.dart';

/// Types a message into a session's composer and presses Return **once the
/// screen shows the words are in the field**, then reads the screen again to
/// see the field let them go. A Return that reaches the agent in the same read
/// as the text is folded into a newline by a composer reading the run as a
/// paste: the message then sits in the field, typed but unsent, which is what
/// the phone's messages did while an agent was working (docs/SETTLED.md). A
/// Return the composer ignored is pressed again — on an empty composer a
/// Return does nothing, so pressing one too many costs nothing.
class SessionMessageTypist {
  SessionMessageTypist({
    required this.readScreen,
    required this.markersFor,
    required this.type,
    required this.press,
    this.poll = const Duration(milliseconds: 50),
    this.typedPatience = const Duration(milliseconds: 1500),
    this.sendPatience = const Duration(seconds: 2),
    this.presses = 3,
  });

  /// The bottom rows of the session's pane, or null without one.
  final List<String>? Function(String sessionId) readScreen;

  /// The glyphs the session's agent starts its composer row with, or null when
  /// its screen was never measured — then the send cannot be verified.
  final List<String>? Function(String sessionId) markersFor;

  /// Types the message into the pane, without its Return; false without one.
  final bool Function(String sessionId, String text) type;

  /// Presses keys in the session's pane; false without one.
  final bool Function(String sessionId, String keys) press;

  final Duration poll;

  /// How long the words may take to show in the composer before Return is
  /// pressed anyway.
  final Duration typedPatience;

  /// How long the composer may take to let one Return's message go.
  final Duration sendPatience;

  /// How many Returns a message may cost, the first included.
  final int presses;

  static const _enter = '\r';

  /// Types [text] into [sessionId] and presses Return until the composer lets
  /// it go. False when the session has no live pane — the caller relaunches
  /// then. Throws [SessionPromptRefusal] when the words were typed but the
  /// composer kept them: the message is on screen, and saying it was sent
  /// would be a lie.
  Future<bool> send(String sessionId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (!type(sessionId, trimmed)) return false;

    final markers = markersFor(sessionId);
    final probe = messageProbe(trimmed);
    // A long message a composer folds into "[Pasted text #1]" never shows its
    // words. Then there is nothing to read the send back from, and it is left
    // at one Return, exactly as it was before this class.
    final typed =
        markers != null &&
        await _until(sessionId, (rows) => composerHolds(rows, markers, probe));
    if (!press(sessionId, _enter)) return false;
    if (!typed) return true;

    for (var pressed = 1; ; pressed++) {
      if (await _until(
        sessionId,
        (rows) => !composerHolds(rows, markers, probe),
        within: sendPatience,
      )) {
        return true;
      }
      if (pressed >= presses) {
        throw const SessionPromptRefusal(
          'the message was typed into this session but its composer did not '
          'send it — it is still in the field, so press Return in its '
          'terminal',
        );
      }
      press(sessionId, _enter);
    }
  }

  /// Whether [test] holds of the pane's rows before [within] runs out.
  Future<bool> _until(
    String sessionId,
    bool Function(List<String> rows) test, {
    Duration? within,
  }) async {
    final deadline = DateTime.now().add(within ?? typedPatience);
    while (!test(readScreen(sessionId) ?? const [])) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(poll);
    }
    return true;
  }
}

/// Whether the composer on [rows] still holds [probe]. The composer is the
/// lowest row starting with one of the agent's [markers], and the rows its
/// text wraps on to below it: a message the agent took is drawn *above* that
/// row — queued, or answered — so what is read here is what is still in the
/// field.
bool composerHolds(List<String> rows, List<String> markers, String probe) {
  var at = -1;
  for (var i = rows.length - 1; i >= 0 && at < 0; i--) {
    final trimmed = rows[i].trimLeft();
    if (markers.any(trimmed.startsWith)) at = i;
  }
  if (at < 0) return false;
  return _flat(rows.sublist(at).join(' ')).contains(probe);
}

/// The words a sent message is looked for by: enough of it to name it, and no
/// more — a composer wraps the rest across rows and columns.
String messageProbe(String text) {
  final flat = _flat(text);
  return flat.length > 40 ? flat.substring(0, 40) : flat;
}

String _flat(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');
