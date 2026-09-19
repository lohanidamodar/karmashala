import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminal_grid_text.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';

/// Why a menu or a question was not answered. Nothing was chosen when this is
/// thrown — at worst the highlight was moved and left there.
class SessionPromptRefusal implements Exception {
  const SessionPromptRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

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
    final menu = read(sessionId);
    if (menu == null) {
      throw const SessionPromptRefusal('no menu is open in this session now');
    }
    if (menu.id != menuId) {
      throw const SessionPromptRefusal(
        'the prompt changed since it was shown, so nothing was chosen',
      );
    }
    if (option < 0 || option >= menu.options.length) {
      throw const SessionPromptRefusal('that menu has no such option');
    }
    final label = menu.options[option];
    // One step at a time, each seen before the next: a burst sent as the menu
    // draws can be dropped (docs/SETTLED.md).
    final deadline = DateTime.now().add(patience);
    var at = menu.highlighted;
    while (at != option) {
      if (!press(sessionId, support.move(at, at < option ? at + 1 : at - 1))) {
        throw const SessionPromptRefusal('this session has no live terminal');
      }
      final before = at;
      final stepDeadline = DateTime.now().add(_step);
      while (at == before) {
        await Future<void>.delayed(poll);
        final now = read(sessionId);
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

final sessionMenuAnswererProvider = Provider<SessionMenuAnswerer>((ref) {
  AgentDescriptor? agentOf(String sessionId) {
    final session = ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return null;
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    return agentId == null
        ? null
        : ref.read(agentRegistryProvider).byId(agentId);
  }

  return SessionMenuAnswerer(
    readScreen: (sessionId) {
      final paneId = ref.read(sessionLauncherProvider).livePaneFor(sessionId);
      if (paneId == null) return null;
      final instance = ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
      if (instance == null) return null;
      return terminalTailLines(instance.terminal, lines: kMenuScreenRows);
    },
    supportFor: (sessionId) => agentOf(sessionId)?.menus,
    isAsking: (sessionId) =>
        ref.read(sessionStatusLookupProvider)(sessionId)?.hasOpenPrompt ??
        false,
    press: (sessionId, keys) =>
        ref.read(sessionLauncherProvider).pressKeys(sessionId, keys),
  );
});
