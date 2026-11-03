import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/ask_toasts.dart';
import 'package:karmashala_ui/theme.dart';

/// The ask toast (UI overhaul spec §5), drawn from values.
void main() {
  const ask = OffScreenAsk(
    openId: 's1',
    label: 'Trail API pagination',
    imported: false,
    detail: 'Do you want to run npm test?',
    canAnswer: true,
  );

  Future<List<String>> pump(
    WidgetTester tester,
    OffScreenAsk ask, {
    bool answerable = true,
  }) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: AskToast(
              ask: ask,
              onAnswer: answerable
                  ? (approve) => events.add(approve ? 'yes' : 'no')
                  : null,
              onOpen: () => events.add('open'),
              onDismiss: () => events.add('dismiss'),
            ),
          ),
        ),
      ),
    );
    return events;
  }

  testWidgets('says who is asking and what, and answers in place', (
    tester,
  ) async {
    final events = await pump(tester, ask);
    expect(find.text('Trail API pagination needs you'), findsOneWidget);
    expect(find.text('Do you want to run npm test?'), findsOneWidget);

    await tester.tap(find.text('Yes'));
    await tester.tap(find.text('No'));
    await tester.tap(find.text('Open'));
    await tester.tap(find.byTooltip('Dismiss'));
    expect(events, ['yes', 'no', 'open', 'dismiss']);
  });

  testWidgets('an ask that can only be answered in its terminal offers Open', (
    tester,
  ) async {
    await pump(tester, ask, answerable: false);
    expect(find.text('Yes'), findsNothing);
    expect(find.text('No'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('an ask with nothing readable still names the session', (
    tester,
  ) async {
    const quiet = OffScreenAsk(
      openId: 's2',
      label: 'Lake generator polish',
      imported: false,
      detail: null,
      canAnswer: false,
    );
    await pump(tester, quiet, answerable: false);
    expect(find.text('Lake generator polish needs you'), findsOneWidget);
  });
  group("Codex's command prompt, read off its screen", () {
    final codex = AgentRegistry.builtIn.byId(AgentIds.codex)!;
    final report = AgentStatusReport(
      agentId: AgentIds.codex,
      sessionId: 'c1',
      status: AgentActivityStatus.awaitingApproval,
      source: AgentStatusSource.terminalGrid,
      observedAt: DateTime.utc(2026, 11, 3),
      waiting: AgentWaitKind.approval,
      evidence: const [
        '  Would you like to run the following command?',
        '',
        '  Environment: local',
        '',
        '  Reason: May I create the requested consolidation branch?',
        '',
        r'  $ git switch -c feature/typing-games',
        '',
        '› 1. Yes, proceed (y)',
        "  2. Yes, and don't ask again for commands that start with `git switch -c` (p)",
        '  3. No, and tell Codex what to do differently (esc)',
        '',
        '• Press enter to confirm or esc to cancel',
      ],
    );

    test('the toast quotes the command and its reason, not the footer', () {
      final detail = askToastDetail(report, codex.menus)!;
      expect(detail, contains(r'$ git switch -c feature/typing-games'));
      expect(detail, contains('Reason: May I create'));
      expect(detail, isNot(contains('Press enter')));
    });

    test('Yes and No answer it, through the menu', () {
      expect(askToastAnswers(codex, report), isTrue);
    });

    test('with no menu on screen, No has nothing to press', () {
      final bare = AgentStatusReport(
        agentId: AgentIds.codex,
        sessionId: 'c1',
        status: AgentActivityStatus.awaitingApproval,
        source: AgentStatusSource.terminalGrid,
        observedAt: DateTime.utc(2026, 11, 3),
        waiting: AgentWaitKind.approval,
        evidence: const ['Press enter to continue'],
      );
      expect(askToastAnswers(codex, bare), isFalse);
      expect(askToastDetail(bare, codex.menus), 'Press enter to continue');
    });
  });
}
