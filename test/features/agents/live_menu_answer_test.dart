@Tags(['live-agent'])
library;

import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';

import 'live_agent_screen.dart';

/// The production [SessionMenuAnswerer], answering the real CLIs' own menus in
/// a real ConPTY and xterm2 grid — the proof that choosing an option from the
/// phone or the chat view chooses that option, where Approve (Enter) would
/// have chosen whatever was highlighted.
///
///   KARMASHALA_CLAUDE=C:\Users\me\.local\bin\claude.exe \
///   KARMASHALA_CODEX=C:\...\codex.exe \
///     flutter test --tags=live-agent test/features/agents/live_menu_answer_test.dart
///
/// Starts in fresh temp folders, so each run leaves one trusted folder behind
/// in the CLI's own config. Spends no model turn.
void main() {
  final claude = Platform.environment['KARMASHALA_CLAUDE'];
  final codex = Platform.environment['KARMASHALA_CODEX'];
  final registry = AgentRegistry.builtIn;

  SessionMenuAnswerer answererOn(LiveAgentScreen screen, String agentId) =>
      SessionMenuAnswerer(
        readScreen: (_) =>
            terminalTailLines(screen.terminal, lines: kMenuScreenRows),
        supportFor: (_) => registry.byId(agentId)!.menus,
        isAsking: (_) => true,
        press: (_, keys) {
          // One write, as the pane's own textInput delivers it.
          screen.write(keys);
          return true;
        },
      );

  String freshFolder({Map<String, String> files = const {}}) {
    final dir = Directory.systemTemp.createTempSync('ks-menu-').path;
    for (final entry in files.entries) {
      File('$dir${Platform.pathSeparator}${entry.key}')
        ..createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    return dir;
  }

  Future<AgentScreenMenu> menuShowing(
    SessionMenuAnswerer answerer,
    String option,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      final menu = answerer.read('s');
      if (menu != null && menu.options.contains(option)) return menu;
      if (DateTime.now().isAfter(deadline)) {
        fail('no menu offering "$option" appeared');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  group(
    'Claude Code',
    skip: claude == null ? 'set KARMASHALA_CLAUDE' : false,
    () {
      test(
        'folder trust: choosing "Yes" trusts it, where Enter exits',
        () async {
          final screen = LiveAgentScreen.start(
            argv: [claude!, '--model', 'haiku'],
            workingDirectory: freshFolder(),
            environment: const {'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE': '1'},
          );
          addTearDown(screen.close);
          final answerer = answererOn(screen, AgentIds.claudeCode);
          final menu = await menuShowing(answerer, 'Yes, I trust this folder');
          expect(menu.options[menu.highlighted], 'No, exit');

          await answerer.choose(
            's',
            menuId: menu.id,
            option: menu.options.indexOf('Yes, I trust this folder'),
          );

          await screen.until(
            (s) => s.contains('for shortcuts') || s.contains('shift+tab'),
            what: 'the composer',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test(
        'a project MCP server: choosing the first option, from the last',
        () async {
          final screen = LiveAgentScreen.start(
            argv: [claude!, '--model', 'haiku'],
            workingDirectory: freshFolder(
              files: {
                '.mcp.json':
                    '{"mcpServers":{"probe":{"command":"cmd","args":["/c","exit"]}}}',
              },
            ),
            environment: const {'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE': '1'},
          );
          addTearDown(screen.close);
          final answerer = answererOn(screen, AgentIds.claudeCode);
          final trust = await menuShowing(answerer, 'Yes, I trust this folder');
          await answerer.choose('s', menuId: trust.id, option: 1);

          final mcp = await menuShowing(answerer, 'Use this MCP server');
          expect(mcp.highlighted, mcp.options.length - 1);
          final chosen = await answerer.choose('s', menuId: mcp.id, option: 0);

          expect(chosen, 'Use this MCP server');
          await screen.until(
            (s) => s.contains('for shortcuts') || s.contains('shift+tab'),
            what: 'the composer',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
  );

  group('Codex', skip: codex == null ? 'set KARMASHALA_CODEX' : false, () {
    // Only while this Codex has an update to offer; without one the menu
    // never appears and the test says so.
    test('the update offer: "Skip" skips, where Enter would update', () async {
      final screen = LiveAgentScreen.start(
        argv: [codex!],
        workingDirectory: freshFolder(),
      );
      addTearDown(screen.close);
      final answerer = answererOn(screen, AgentIds.codex);
      final offer = await menuShowing(answerer, 'Skip');
      expect(offer.options[offer.highlighted], startsWith('Update now'));

      final chosen = await answerer.choose(
        's',
        menuId: offer.id,
        option: offer.options.indexOf('Skip'),
      );

      expect(chosen, 'Skip');
      await menuShowing(answerer, 'Yes, continue');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('directory trust: moving to "No, quit" is seen before it is '
        'chosen', () async {
      final screen = LiveAgentScreen.start(
        argv: [codex!, '-c', 'check_for_update_on_startup=false'],
        workingDirectory: freshFolder(),
      );
      addTearDown(screen.close);
      final answerer = answererOn(screen, AgentIds.codex);
      final trust = await menuShowing(answerer, 'No, quit');

      await answerer.choose('s', menuId: trust.id, option: 1);

      expect(
        await screen.exitCode.timeout(const Duration(seconds: 20)),
        isNotNull,
        reason: '"No, quit" quits',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('directory trust: "Yes, continue" reaches the composer', () async {
      final screen = LiveAgentScreen.start(
        argv: [codex!, '-c', 'check_for_update_on_startup=false'],
        workingDirectory: freshFolder(),
      );
      addTearDown(screen.close);
      final answerer = answererOn(screen, AgentIds.codex);
      final trust = await menuShowing(answerer, 'Yes, continue');

      await answerer.choose('s', menuId: trust.id, option: 0);

      await screen.untilShows('Ask Codex');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
