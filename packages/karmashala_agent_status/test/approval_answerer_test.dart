import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import 'fixture_menu_screen.dart';

/// Approve and deny on the prompts the real CLIs draw, replayed from captured
/// PTY streams into a real grid and read the way the app reads a pane
/// (`terminalTailLines` over [kMenuScreenRows], then the adapter's
/// [AgentMenuSupport]). What is asserted is what reached the terminal.
///
/// The bug this pins: `session_answer {decision: "approve"}` on Claude Code's
/// folder trust sent a bare Enter, which confirmed the highlighted
/// `No, exit` — and Claude Code quit.
void main() {
  late FixtureMenuScreen screen;
  late List<({bool granted, String option})> recorded;

  SessionApprovalAnswerer answererFor(
    AgentDescriptor agent, {
    AgentMenuSupport? menus,
    bool question = false,
  }) => SessionApprovalAnswerer(
    menus: SessionMenuAnswerer(
      readScreen: (_) => screen.rows(),
      supportFor: (_) => menus ?? agent.menus,
      isAsking: (_) => true,
      press: (_, keys) => screen.press(keys),
      poll: const Duration(milliseconds: 1),
      patience: const Duration(milliseconds: 300),
    ),
    rulesFor: (_) => agent.approval,
    agentNameFor: (_) => agent.displayName,
    hasOpenQuestion: (_) => question,
    pressAnswerKey:
        (_, keys, {required decidedBy, required decidedBySessionId}) =>
            screen.press(keys),
    recordMenuAnswer:
        (
          _, {
          required granted,
          required option,
          required effect,
          required decidedBy,
          required decidedBySessionId,
        }) => recorded.add((granted: granted, option: option)),
  );

  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  final codex = AgentRegistry.builtIn.byId(AgentIds.codex)!;

  setUp(() => recorded = []);

  group('Claude Code folder trust (claude-code-trust-prompt.raw)', () {
    setUp(
      () => screen = FixtureMenuScreen.fixture(
        'claude-code-trust-prompt',
        marker: '❯',
      ),
    );

    test('the capture is the screen the bug was found on', () {
      final menu = readScreenMenu(screen.rows(), claude.menus!)!;
      expect(menu.options, ['No, exit', 'Yes, I trust this folder']);
      expect(menu.highlighted, 0, reason: 'Enter alone would exit');
    });

    test(
      'approve moves to "Yes, I trust this folder", then confirms',
      () async {
        final answer = await answererFor(claude).answer('s', approve: true);

        expect(screen.sent, ['\x1b[B', '\r']);
        expect(screen.confirmed, 'Yes, I trust this folder');
        expect(answer.answered, 'Yes, I trust this folder');
        expect(answer.effect, contains('"Yes, I trust this folder"'));
        expect(recorded, [(granted: true, option: 'Yes, I trust this folder')]);
      },
    );

    test(
      'deny chooses "No, exit" by name and says so — not a bare Esc',
      () async {
        final answer = await answererFor(claude).answer('s', approve: false);

        // Esc on this modal exits too, so it is not the "safe cancel" the
        // permission modal has: the row is chosen, and named.
        expect(screen.sent, ['\r']);
        expect(screen.confirmed, 'No, exit');
        expect(answer.answered, 'No, exit');
        expect(answer.effect, contains('"No, exit"'));
        expect(recorded, [(granted: false, option: 'No, exit')]);
      },
    );

    test(
      'a menu with no declared affirmative is refused, nothing pressed',
      () async {
        final bare = AgentMenuSupport(markers: claude.menus!.markers);

        await expectLater(
          answererFor(claude, menus: bare).answer('s', approve: true),
          throwsA(
            isA<SessionPromptRefusal>().having(
              (r) => r.message,
              'message',
              allOf(contains('nothing was pressed'), contains('"No, exit"')),
            ),
          ),
        );
        expect(screen.sent, isEmpty);
        expect(recorded, isEmpty);
      },
    );

    test('a question screen is never answered as a menu', () async {
      // Falls back to the declared key, as before this change.
      await answererFor(claude, question: true).answer('s', approve: true);
      expect(screen.sent, ['\r']);
      expect(recorded, isEmpty);
    });
  });

  group('Claude Code tool permission (claude-code-permission-modal.raw)', () {
    setUp(
      () => screen = FixtureMenuScreen.fixture(
        'claude-code-permission-modal',
        marker: '❯',
      ),
    );

    test(
      'approve is Enter on the highlighted plain "Yes", as before',
      () async {
        final answer = await answererFor(claude).answer('s', approve: true);

        expect(screen.sent, ['\r']);
        expect(screen.confirmed, 'Yes');
        expect(
          answer.answered,
          'Yes',
          reason: 'not "Yes, and switch to accept edits …"',
        );
      },
    );

    test(
      'deny is the declared Esc, unchanged: it declines the tool call',
      () async {
        final answer = await answererFor(claude).answer('s', approve: false);

        expect(screen.sent, ['\x1b']);
        expect(screen.confirmed, isNull);
        expect(answer.answered, claude.approval.deny!.label);
        expect(answer.effect, startsWith(claude.approval.deny!.effect));
        expect(answer.effect, contains('Do you want to create note.txt?'));
      },
    );
  });

  group('Codex directory trust (codex-approval-prompt.raw)', () {
    setUp(
      () => screen = FixtureMenuScreen.fixture(
        'codex-approval-prompt',
        marker: '›',
        fraction: 0.019,
      ),
    );

    test('approve confirms the highlighted "Yes, continue"', () async {
      final answer = await answererFor(codex).answer('s', approve: true);

      expect(screen.sent, ['\r']);
      expect(answer.answered, 'Yes, continue');
    });

    test('deny chooses "No, quit", though Codex names no deny key', () async {
      expect(codex.approval.deny, isNull);

      final answer = await answererFor(codex).answer('s', approve: false);

      expect(screen.sent, ['\x1b[B', '\r']);
      expect(screen.confirmed, 'No, quit');
      expect(answer.answered, 'No, quit');
    });
  });

  test('Codex update offer: no option means yes, so approve refuses', () async {
    // The menu measured on 0.154.0 (screen_menu_test.dart), drawn as output.
    screen = FixtureMenuScreen.text(
      [
        '  ✨ Update available! 0.154.0 -> 0.155.1',
        '',
        '› 1. Update now',
        '  2. Skip',
        '  3. Skip until next version',
        '',
        '  Press enter to continue',
      ].join('\r\n'),
      marker: '›',
    );

    await expectLater(
      answererFor(codex).answer('s', approve: true),
      throwsA(isA<SessionPromptRefusal>()),
    );
    await expectLater(
      answererFor(codex).answer('s', approve: false),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(screen.sent, isEmpty, reason: 'Enter would run the updater');
  });

  test('no menu on screen: the declared keys, exactly as before', () async {
    screen = FixtureMenuScreen.text('', marker: '❯');

    final approve = await answererFor(claude).answer('s', approve: true);
    final deny = await answererFor(claude).answer('s', approve: false);

    expect(screen.sent, ['\r', '\x1b']);
    expect(approve.answered, claude.approval.approve!.label);
    expect(approve.effect, claude.approval.approve!.effect);
    expect(deny.answered, claude.approval.deny!.label);
    await expectLater(
      answererFor(codex).answer('s', approve: false),
      throwsA(
        isA<SessionPromptRefusal>().having(
          (r) => r.message,
          'message',
          contains('names no way to deny'),
        ),
      ),
    );
  });
}
