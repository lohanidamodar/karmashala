@Tags(['live-agent'])
library;

import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_menu_answerer.dart';
import 'package:karmashala/src/features/sessions/application/session_message_typist.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';

import 'live_agent_screen.dart';

/// The production [SessionMessageTypist] typing into the real CLI's own
/// composer, in a real ConPTY and xterm2 grid — the proof that a message sent
/// from the phone while the agent works is queued rather than left sitting in
/// the field, and that [composerHolds] reads that field off the real screen.
///
///   KARMASHALA_CLAUDE=C:\Users\me\.local\bin\claude.exe \
///     flutter test --tags=live-agent test/features/agents/live_message_send_test.dart
///
/// Starts in a fresh temp folder, so each run leaves one trusted folder behind
/// in the CLI's own config. Spends model turns: the agent is given work to do
/// so there is something to queue behind.
void main() {
  final claude = Platform.environment['KARMASHALA_CLAUDE'];
  final registry = AgentRegistry.builtIn;
  final markers = registry.byId(AgentIds.claudeCode)!.menus!.markers;

  List<String> rowsOf(LiveAgentScreen screen) =>
      terminalTailLines(screen.terminal, lines: kMenuScreenRows);

  ({SessionMessageTypist typist, List<String> pressed}) typistOn(
    LiveAgentScreen screen,
  ) {
    final pressed = <String>[];
    return (
      pressed: pressed,
      typist: SessionMessageTypist(
        readScreen: (_) => rowsOf(screen),
        markersFor: (_) => markers,
        // One write each, as the pane's own textInput delivers them.
        type: (_, text) {
          screen.send('$text\x05');
          return true;
        },
        press: (_, keys) {
          pressed.add(keys);
          screen.send(keys);
          return true;
        },
      ),
    );
  }

  Future<LiveAgentScreen> claudeAtItsComposer() async {
    final screen = LiveAgentScreen.start(
      argv: [claude!, '--model', 'haiku'],
      workingDirectory: Directory.systemTemp.createTempSync('ks-send-').path,
      environment: const {'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE': '1'},
    );
    addTearDown(screen.close);
    final answerer = SessionMenuAnswerer(
      readScreen: (_) => rowsOf(screen),
      supportFor: (_) => registry.byId(AgentIds.claudeCode)!.menus,
      isAsking: (_) => true,
      press: (_, keys) {
        screen.send(keys);
        return true;
      },
    );
    // Answered until the composer is there: an Enter the prompt drops leaves
    // it asking, and this is the setup, not the measurement.
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    bool atComposer() =>
        screen.text.contains('for shortcuts') ||
        screen.text.contains('shift+tab');
    while (!atComposer()) {
      final menu = answerer.read('s');
      if (menu != null && menu.options.contains('Yes, I trust this folder')) {
        try {
          await answerer.choose(
            's',
            menuId: menu.id,
            option: menu.options.indexOf('Yes, I trust this folder'),
          );
        } on SessionPromptRefusal {
          // The prompt redrew under the move; read it again.
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('never reached the composer:\n${screen.text}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return screen;
  }

  group(
    'Claude Code',
    skip: claude == null ? 'set KARMASHALA_CLAUDE' : false,
    () {
      test('the field is read as the field: the words are in it before the '
          'Return, and gone after', () async {
        final screen = await claudeAtItsComposer();
        const message = 'PROBE-MESSAGE do not answer this';
        final probe = messageProbe(message);

        screen.send('$message\x05');
        await screen.until(
          (_) => composerHolds(rowsOf(screen), markers, probe),
          what: 'the words in the composer',
        );

        screen.send('\r');

        await screen.until(
          (_) => !composerHolds(rowsOf(screen), markers, probe),
          what: 'the composer letting them go',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      test(
        'a message sent while the agent works is queued, at one Return',
        () async {
          final screen = await claudeAtItsComposer();
          final first = typistOn(screen);
          await first.typist.send(
            's',
            'Count from 1 to 40, one number per line, nothing else.',
          );
          await screen.untilShows('esc to interrupt');

          final second = typistOn(screen);
          // No throw: the words were seen in the field, and seen to leave it.
          expect(await second.typist.send('s', 'QUEUED-WHILE-WORKING'), isTrue);

          expect(second.pressed, ['\r'], reason: 'one Return, not a burst');
          expect(screen.text, contains('QUEUED-WHILE-WORKING'));
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    },
  );
}
