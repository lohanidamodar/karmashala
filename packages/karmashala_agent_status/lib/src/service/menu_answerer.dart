import 'package:agent_cli/descriptors.dart';

import '../domain/prompt_refusal.dart';

/// Reads the menu a session's agent has drawn — folder trust, a permission
/// prompt, a startup offer — and answers it **by option**: the highlight is
/// moved, the screen read again until it sits on the chosen row, and only then
/// is it confirmed. The chat view and the phone both answer through this.
class SessionMenuAnswerer {
  SessionMenuAnswerer({
    required this.readScreen,
    required this.supportFor,
    required this.isAsking,
    required this.press,
    this.poll = const Duration(milliseconds: 100),
    this.patience = const Duration(seconds: 3),
  });

  /// The bottom rows of the session's live pane, or null without one.
  final List<String>? Function(String sessionId) readScreen;

  /// How the session's agent draws its menus, or null when never measured.
  final AgentMenuSupport? Function(String sessionId) supportFor;

  /// Whether the session is stopped on a prompt of the approval kind. A
  /// question has its own reader: its screen has descriptions and a free-text
  /// row a menu does not, and reading it as one would answer it wrongly.
  final bool Function(String sessionId) isAsking;

  /// Presses keys in the session's pane; false without one.
  final bool Function(String sessionId, String keys) press;

  final Duration poll;

  /// How long the highlight may take to reach the chosen row.
  final Duration patience;

  /// How long one step may take to show before its key is pressed again.
  Duration get _step => patience ~/ 6;

  /// The menu open in [sessionId] now, or null.
  AgentScreenMenu? read(String sessionId) {
    if (!isAsking(sessionId)) return null;
    return onScreen(sessionId);
  }

  /// The menu drawn on [sessionId]'s screen now, whatever its status says, or
  /// null. For a caller that has already decided a prompt is being answered
  /// and must not press Enter blind on a menu the status has not caught up
  /// with; a surface offering a menu reads [read].
  AgentScreenMenu? onScreen(String sessionId) {
    final support = supportFor(sessionId);
    final rows = readScreen(sessionId);
    if (support == null || rows == null) return null;
    return readScreenMenu(rows, support);
  }

  /// Chooses option [option] of the menu named [menuId], and returns its words.
  Future<String> choose(
    String sessionId, {
    required String menuId,
    required int option,
  }) async {
    final support = supportFor(sessionId);
    if (support == null) {
      throw const SessionPromptRefusal(
        "this agent's menus can only be answered in its terminal",
      );
    }
    // The screen itself, not the status: [menuId] already names the menu the
    // caller saw, and a status lagging the screen must not strand the answer.
    final menu = onScreen(sessionId);
    // Both stale: the menu that was shown was answered — at the desk, or by
    // the agent itself (auto mode) — before this arrived.
    if (menu == null) {
      throw const SessionPromptRefusal(
        'no menu is open in this session now',
        stale: true,
      );
    }
    if (menu.id != menuId) {
      throw const SessionPromptRefusal(
        'the prompt changed since it was shown, so nothing was chosen',
        stale: true,
      );
    }
    if (option < 0 || option >= menu.options.length) {
      throw const SessionPromptRefusal('that menu has no such option');
    }
    final label = menu.options[option];
    // One step at a time, each seen before the next: a burst sent as the menu
    // draws can be dropped.
    final deadline = DateTime.now().add(patience);
    var at = menu.highlighted;
    while (at != option) {
      if (!press(sessionId, support.move(at, at < option ? at + 1 : at - 1))) {
        throw const SessionPromptRefusal(
          'this session has no live terminal',
          noTerminal: true,
        );
      }
      final before = at;
      final stepDeadline = DateTime.now().add(_step);
      while (at == before) {
        await Future<void>.delayed(poll);
        final now = onScreen(sessionId);
        if (now == null || now.id != menuId) {
          throw const SessionPromptRefusal(
            'the prompt changed while moving to that option, so nothing was '
            'chosen',
          );
        }
        at = now.highlighted;
        // A key the menu dropped is pressed again, not waited on for ever.
        if (DateTime.now().isAfter(stepDeadline)) break;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          'the highlight did not reach "$label", so nothing was chosen — '
          'check the terminal',
        );
      }
    }
    if (!press(sessionId, support.choose)) {
      throw const SessionPromptRefusal('this session has no live terminal');
    }
    return label;
  }
}

/// Rows read for a menu: more than the status source's twelve, because a menu's
/// prompt sits above its options — the folder-trust screen is fourteen rows.
const kMenuScreenRows = 40;
