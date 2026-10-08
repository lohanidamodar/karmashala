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
    final (support, menu) = _open(sessionId, menuId);
    // Enter on its last row submits whatever happens to be ticked, which is
    // an answer only the ticks can give.
    if (menu.isChecklist) {
      throw const SessionPromptRefusal(
        'this prompt is a checklist: answer it with the boxes to tick, so '
        'nothing was chosen',
      );
    }
    if (option < 0 || option >= menu.options.length) {
      throw const SessionPromptRefusal('that menu has no such option');
    }
    await _moveTo(sessionId, support, menu, option);
    if (!press(sessionId, support.choose)) {
      throw const SessionPromptRefusal('this session has no live terminal');
    }
    return menu.options[option];
  }

  /// Submits the checklist named [menuId] with exactly [ticks] ticked, box by
  /// box ([AgentScreenMenu.boxes]): each box that differs is moved to and
  /// toggled, and seen to change, before the submit row is confirmed and the
  /// checklist seen to go. Returns the options left ticked.
  Future<List<String>> submitChecklist(
    String sessionId, {
    required String menuId,
    required List<bool> ticks,
  }) async {
    var (support, menu) = _open(sessionId, menuId);
    final submit = menu.submit;
    if (!menu.isChecklist || submit == null) {
      throw const SessionPromptRefusal(
        'this prompt is not a checklist, so nothing was ticked',
      );
    }
    final boxes = menu.boxes;
    if (ticks.length != boxes.length) {
      throw const SessionPromptRefusal(
        'the answer does not name every box of that checklist, so nothing '
        'was ticked',
      );
    }
    for (var b = 0; b < boxes.length; b++) {
      final row = boxes[b];
      if (menu.checked[row] == ticks[b]) continue;
      menu = await _moveTo(sessionId, support, menu, row);
      if (!press(sessionId, support.toggle)) {
        throw const SessionPromptRefusal(
          'this session has no live terminal',
          noTerminal: true,
        );
      }
      // Never pressed twice: a toggle that lands late would undo itself.
      final deadline = DateTime.now().add(patience);
      while (true) {
        await Future<void>.delayed(poll);
        final now = _still(sessionId, menuId);
        if (now.checked[row] == ticks[b]) {
          menu = now;
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw SessionPromptRefusal(
            'the box for "${menu.options[row]}" did not change, so the '
            'checklist was not submitted — check the terminal',
            unconfirmed: true,
          );
        }
      }
    }
    await _moveTo(sessionId, support, menu, submit);
    if (!press(sessionId, support.choose)) {
      throw const SessionPromptRefusal('this session has no live terminal');
    }
    await _gone(
      sessionId,
      menuId,
      'pressed Enter on "${menu.options[submit]}"',
    );
    return [
      for (var b = 0; b < boxes.length; b++)
        if (ticks[b]) menu.options[boxes[b]],
    ];
  }

  /// Leaves the checklist named [menuId] by the agent's cancel, with nothing
  /// ticked, and sees it go.
  Future<void> dismiss(String sessionId, {required String menuId}) async {
    final (support, menu) = _open(sessionId, menuId);
    if (!menu.isChecklist) {
      throw const SessionPromptRefusal(
        'this prompt is not a checklist, so nothing was pressed',
      );
    }
    if (!press(sessionId, support.cancel)) {
      throw const SessionPromptRefusal(
        'this session has no live terminal',
        noTerminal: true,
      );
    }
    await _gone(sessionId, menuId, 'pressed Esc');
  }

  /// How the agent draws menus, and the menu named [menuId] — the screen
  /// itself, not the status: [menuId] already names the menu the caller saw,
  /// and a status lagging the screen must not strand the answer.
  (AgentMenuSupport, AgentScreenMenu) _open(String sessionId, String menuId) {
    final support = supportFor(sessionId);
    if (support == null) {
      throw const SessionPromptRefusal(
        "this agent's menus can only be answered in its terminal",
      );
    }
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
    return (support, menu);
  }

  /// The menu named [menuId], still on screen mid-answer.
  AgentScreenMenu _still(String sessionId, String menuId) {
    final now = onScreen(sessionId);
    if (now == null || now.id != menuId) {
      throw const SessionPromptRefusal(
        'the prompt changed while it was being answered — check the terminal',
        unconfirmed: true,
      );
    }
    return now;
  }

  /// Waits for the menu named [menuId] to leave the screen after [pressed].
  Future<void> _gone(String sessionId, String menuId, String pressed) async {
    final deadline = DateTime.now().add(patience);
    while (true) {
      await Future<void>.delayed(poll);
      if (onScreen(sessionId)?.id != menuId) return;
      if (DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          '$pressed, but the prompt is still on screen — check the terminal',
          unconfirmed: true,
        );
      }
    }
  }

  /// Moves [menu]'s highlight to [option] and returns the menu as it then
  /// reads.
  Future<AgentScreenMenu> _moveTo(
    String sessionId,
    AgentMenuSupport support,
    AgentScreenMenu menu,
    int option,
  ) async {
    final menuId = menu.id;
    final label = menu.options[option];
    var now = menu;
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
        final read = onScreen(sessionId);
        if (read == null || read.id != menuId) {
          throw const SessionPromptRefusal(
            'the prompt changed while moving to that option, so nothing was '
            'chosen',
          );
        }
        now = read;
        at = read.highlighted;
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
    return now;
  }
}

/// Rows read for a menu: more than the status source's twelve, because a menu's
/// prompt sits above its options — the folder-trust screen is fourteen rows.
const kMenuScreenRows = 40;
