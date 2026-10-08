import 'package:agent_cli/descriptors.dart' show RewindMenu, RewindMode;

/// The conversation half of a terminal session's rewind: its agent's own
/// menu, answered in its terminal.
abstract interface class TerminalRewind {
  /// Cuts [sessionId]'s conversation back to before the message [back]
  /// messages from its newest, whose words are [words]. Throws [StateError]
  /// in words, with the menu closed, when the screen is not as expected.
  Future<void> rewind(
    String sessionId, {
    required int back,
    required RewindMenu menu,
    String words = '',
  });
}

/// [TerminalRewind] typed into the session's terminal as the host and read
/// back off its screen after every key: the command, Up to the message, its
/// quote checked against [words], the digit of "Restore conversation" (the
/// files are Karmashala's to restore), and the message the menu puts back in
/// the agent's input cleared.
class ScreenTerminalRewind implements TerminalRewind {
  ScreenTerminalRewind({
    required this.screen,
    required this.press,
    this.poll = const Duration(milliseconds: 100),
    this.patience = const Duration(seconds: 4),
  });

  final List<String>? Function(String sessionId) screen;
  final bool Function(String sessionId, String keys) press;
  final Duration poll;
  final Duration patience;

  static const _up = '\x1b[A';
  static const _escape = '\x1b';
  static const _clearLine = '\x15';
  static const _backspace = '\x7f';

  @override
  Future<void> rewind(
    String sessionId, {
    required int back,
    required RewindMenu menu,
    String words = '',
  }) async {
    final choice = menu.labels[RewindMode.conversation]!;
    final pick = RegExp(r'(\d+)\.\s+' + RegExp.escape(choice) + r'\s*$');
    try {
      _press(sessionId, menu.command);
      await Future<void>.delayed(poll);
      _press(sessionId, '\r');
      await _until(sessionId, 'its message list', (lines) {
        return lines.any((l) => l.contains(menu.listMarker));
      });
      _press(sessionId, _up * (back + 1));
      await Future<void>.delayed(poll);
      _press(sessionId, '\r');
      final confirm = await _until(
        sessionId,
        'its confirmation',
        (lines) => lines.any((l) => l.contains(menu.confirmMarker)),
      );
      if (!_quotes(confirm, menu.confirmMarker, words)) {
        throw const _Unexpected('the message it quoted is not this one');
      }
      final digit = [
        for (final line in confirm) ?pick.firstMatch(line.trim())?.group(1),
      ].firstOrNull;
      if (digit == null) throw _Unexpected('no "$choice" choice');
      _press(sessionId, digit);
      await _until(
        sessionId,
        'it to close',
        (lines) => !lines.any(
          (l) => l.contains(menu.listMarker) || l.contains(menu.confirmMarker),
        ),
      );
      // The menu puts the message back in the agent's input; Karmashala's
      // composer holds it instead.
      final lines = '\n'.allMatches(words).length + 1;
      _press(sessionId, '$_clearLine$_backspace' * (lines - 1) + _clearLine);
    } on _Unexpected catch (unexpected) {
      await _close(sessionId, menu);
      throw StateError(
        'The rewind menu in the terminal was not as expected '
        '(${unexpected.what}), so it was closed and nothing was cut. Open '
        'the terminal to rewind there.',
      );
    }
  }

  void _press(String sessionId, String keys) {
    if (!press(sessionId, keys)) {
      throw const _Unexpected('the terminal took no keys');
    }
  }

  Future<List<String>> _until(
    String sessionId,
    String what,
    bool Function(List<String> lines) seen,
  ) async {
    final deadline = DateTime.now().add(patience);
    while (true) {
      final lines = screen(sessionId);
      if (lines == null) throw const _Unexpected('the terminal has ended');
      if (seen(lines)) return lines;
      if (DateTime.now().isAfter(deadline)) {
        throw _Unexpected('no sign of $what');
      }
      await Future<void>.delayed(poll);
    }
  }

  /// Whether the confirmation quotes [words]: its `│` lines after [marker],
  /// as wrapped and cut by the terminal, begin them.
  static bool _quotes(List<String> lines, String marker, String words) {
    final said = _plain(words);
    if (said.isEmpty) return true;
    final from = lines.indexWhere((l) => l.contains(marker));
    final quoted = [
      for (final line in lines.skip(from + 1))
        if (line.trimLeft().startsWith('│'))
          line.trimLeft().substring(1).trim(),
    ];
    if (quoted.isEmpty) return false;
    var shown = _plain(quoted.first);
    if (shown.endsWith('…')) shown = shown.substring(0, shown.length - 1);
    if (shown.isEmpty) return false;
    // A note Karmashala put ahead of the person's words is quoted too.
    final head = said.length > 24 ? said.substring(0, 24) : said;
    return said.startsWith(shown) || shown.contains(head);
  }

  static String _plain(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Escape until neither screen of the menu shows; never once more, which
  /// in an empty input would open it again.
  Future<void> _close(String sessionId, RewindMenu menu) async {
    for (var i = 0; i < 3; i++) {
      final lines = screen(sessionId);
      if (lines == null ||
          !lines.any(
            (l) =>
                l.contains(menu.listMarker) || l.contains(menu.confirmMarker),
          )) {
        return;
      }
      press(sessionId, _escape);
      await Future<void>.delayed(poll * 3);
    }
  }
}

class _Unexpected implements Exception {
  const _Unexpected(this.what);
  final String what;
}
