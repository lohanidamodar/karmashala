import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/subagent_providers.dart';
import 'package:karmashala/src/features/cli_detection/presentation/subagent_turns_tile.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_subagents_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_subagents_panel.dart';
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// The subagent panel: every delegate and child of a session, a side panel
/// at width and a bottom sheet on a phone, each row opening what it names.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 9);

  final list = SessionSubagentList(
    sessionId: 's1',
    note: 'Tool calls this agent delegates are not listed.',
    entries: [
      SessionSubagent(
        kind: SubagentKind.subagent,
        id: 't1',
        title: 'Find the cart bug',
        state: SubagentState.done,
        agent: 'Explore',
        model: 'haiku',
        startedAt: t0,
        endedAt: t0.add(const Duration(minutes: 2, seconds: 5)),
        tokens: 12300,
        finalResult: 'It is in cart.dart line 40.',
        transcriptPath: '/store/s1/subagents/agent-t1.jsonl',
      ),
      SessionSubagent(
        kind: SubagentKind.childSession,
        id: 'c1',
        title: 'Write the tests',
        state: SubagentState.running,
        agent: 'Codex',
        startedAt: t0.add(const Duration(minutes: 1)),
        tokensGap: SubagentTokensGap.notRecorded,
        childSessionId: 'c1',
        link: 'spawn',
      ),
    ],
  );

  Future<_Actions> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionSubagentsProvider.overrideWith((ref, _) => Stream.value(list)),
          clockProvider.overrideWithValue(
            _FixedClock(t0.add(const Duration(minutes: 4))),
          ),
          explorerActionsProvider.overrideWith((ref) => _Actions(ref)),
          subagentTurnsProvider.overrideWith(
            (ref, key) async => const [
              TranscriptMessage(role: 'agent', text: 'Looked in cart.dart'),
            ],
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  Center(child: SessionSubagentsButton(sessionId: 's1')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('session-subagents')));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
          tester.element(find.byType(SessionSubagentsPanel)),
        ).read(explorerActionsProvider)
        as _Actions;
  }

  testWidgets('at desktop width it is a side panel listing each delegate\'s '
      'facts', (tester) async {
    await pump(tester, const Size(1440, 900));
    expect(find.byType(BottomSheet), findsNothing);
    final panel = tester.getRect(find.byType(SessionSubagentsPanel));
    expect(panel.right, 1440);
    expect(panel.width, lessThanOrEqualTo(440));

    expect(find.text('Find the cart bug'), findsOneWidget);
    expect(
      find.text('Explore · haiku · Done · 2m 05s · 12.3k tokens'),
      findsOneWidget,
    );
    expect(find.text('It is in cart.dart line 40.'), findsOneWidget);
    // Still running: its duration counts to now, and no tokens are guessed.
    expect(
      find.text(
        'Codex · default model · Running · 3m 00s · tokens not recorded',
      ),
      findsOneWidget,
    );
    expect(find.text('child session'), findsOneWidget);
    expect(find.textContaining('are not listed'), findsOneWidget);
  });

  testWidgets('on a phone it is a bottom sheet', (tester) async {
    await pump(tester, const Size(390, 844));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Find the cart bug'), findsOneWidget);
    expect(find.text('Write the tests'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a subagent opens its own turns', (tester) async {
    await pump(tester, const Size(1440, 900));
    await tester.tap(find.byKey(const ValueKey('subagent-t1')));
    await tester.pumpAndSettle();
    expect(find.byType(SubagentTurnsTile), findsOneWidget);
    expect(find.text('Looked in cart.dart'), findsOneWidget);
  });

  testWidgets('a child session opens that session and closes the panel', (
    tester,
  ) async {
    final actions = await pump(tester, const Size(1440, 900));
    await tester.tap(find.byKey(const ValueKey('subagent-c1')));
    await tester.pumpAndSettle();
    expect(actions.opened, ['c1']);
    expect(find.byType(SessionSubagentsPanel), findsNothing);
  });

  testWidgets('nothing delegated says so', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionSubagentsProvider.overrideWith(
            (ref, _) =>
                Stream.value(const SessionSubagentList(sessionId: 's1')),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionSubagentsPanel(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No subagents or child sessions yet.'), findsOneWidget);
  });
}

class _Actions extends ExplorerActions {
  _Actions(super.ref);

  final opened = <String>[];

  @override
  Future<ExplorerResult> openNative(String sessionId) async {
    opened.add(sessionId);
    return const ExplorerResult(ExplorerOutcome.started);
  }
}

class _FixedClock implements Clock {
  const _FixedClock(this.now);

  final DateTime now;

  @override
  DateTime nowUtc() => now;
}
