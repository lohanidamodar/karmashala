import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_pipeline_peek.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_today.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';
import 'package:karmashala/src/features/overview/presentation/overview_pipeline_peek.dart';
import 'package:karmashala/src/features/pipelines/application/pipelines_controller.dart';
import 'package:karmashala_automations/pipelines.dart';

import '../../support/fakes.dart';
import 'mission_fixture.dart';

final _now = MissionFixture.now;

PipelineRun _gate({String id = 'run-1'}) => PipelineRun(
  id: id,
  definition: kPipelineTemplates.first,
  repositoryId: 'r1',
  input: 'Add a badge to the cart icon',
  state: PipelineRunState.waiting,
  byPerson: true,
  createdAt: _now.subtract(const Duration(minutes: 12)),
  updatedAt: _now,
  records: [
    PipelineStageRecord(
      stageIndex: 0,
      role: 'Plan',
      attempt: 1,
      state: PipelineStageState.approval,
      sessionId: 'stage-plan',
      answer: 'Plan: a badge on the icon.\nThen a widget test.',
      artifacts: const [PipelineArtifactRef(id: 'a1', title: 'spec.md')],
      startedAt: _now.subtract(const Duration(minutes: 11)),
      finishedAt: _now.subtract(const Duration(minutes: 2)),
    ),
  ],
);

PipelineRun _looping() => PipelineRun(
  id: 'run-2',
  definition: kPipelineTemplates[1],
  repositoryId: 'r1',
  input: 'Fix the flaky test',
  state: PipelineRunState.running,
  createdAt: _now.subtract(const Duration(minutes: 30)),
  updatedAt: _now,
  records: [
    const PipelineStageRecord(
      stageIndex: 0,
      role: 'Implement',
      attempt: 1,
      state: PipelineStageState.done,
    ),
    const PipelineStageRecord(
      stageIndex: 1,
      role: 'Test',
      attempt: 1,
      state: PipelineStageState.loopedBack,
    ),
    const PipelineStageRecord(
      stageIndex: 0,
      role: 'Implement',
      attempt: 2,
      state: PipelineStageState.done,
    ),
    const PipelineStageRecord(
      stageIndex: 1,
      role: 'Test',
      attempt: 2,
      state: PipelineStageState.checking,
    ),
  ],
);

class _Runs extends PipelinesController {
  _Runs(this.seed);

  final List<PipelineRun> seed;

  @override
  PipelinesState build() =>
      PipelinesState(loaded: true, runs: {for (final r in seed) r.id: r});
}

/// **A pipeline run on the dashboard**: its card says where it is, what it
/// waits on and its stage's last line; a click opens its peek — round 80's
/// run, every stage, the gate — and a stage clicked shows its session's chat
/// there, with a way back. On a phone the peek is a page.
void main() {
  group('the card\'s words', () {
    test('where a run is, and its loops once it has looped', () {
      expect(pipelineRunProgress(_gate(), now: _now), 'Stage 1 of 3 · 12m');
      final loopCap = kPipelineTemplates[1].stages[1].loopCap;
      expect(
        pipelineRunProgress(_looping(), now: _now),
        'Stage 2 of 2 · 30m · loop 1/$loopCap',
      );
    });

    test('what it waits on', () {
      expect(
        pipelineRunWaitingOn(_gate()),
        'Waiting on you: approve what Plan hands on',
      );
      expect(pipelineRunWaitingOn(_looping()), 'Waiting on the checks at Test');
      expect(
        pipelineRunWaitingOn(_looping(), asking: _looping().records.last),
        'Waiting on you: Test asks something',
      );
      expect(
        pipelineRunWaitingOn(
          _gate().copyWith(
            state: PipelineRunState.failed,
            reason: 'The agent stopped with an error.',
          ),
        ),
        'Stuck at Plan: The agent stopped with an error.',
      );
      expect(
        pipelineRunWaitingOn(
          _gate().copyWith(state: PipelineRunState.finished),
        ),
        isNull,
      );
    });

    test('the stage\'s last line: what it does, else what it said', () {
      final record = _gate().current;
      expect(
        pipelineStageLastLine(record, doing: 'Run the tests'),
        'Run the tests',
      );
      expect(pipelineStageLastLine(record, lastAnswer: 'one\n\ntwo\n'), 'two');
      expect(pipelineStageLastLine(record), 'Then a widget test.');
      expect(pipelineStageLastLine(null), isNull);
    });
  });

  test('a failed run is stuck on the Today strip', () {
    const today = OverviewToday(failed: 1, pipelinesFailed: 2);
    expect(today.stuck, 3);
    expect(today.stuckDetail, '1 failed · 2 pipelines failed');
    expect(today, isNot(const OverviewToday(failed: 1, pipelinesFailed: 1)));
  });

  group('the peek', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(FixedClock(_now)),
          pipelinesProvider.overrideWith(() => _Runs([_gate()])),
          workspaceSessionsProvider.overrideWith(
            (ref) => [
              WorkspaceSessionEntry(
                id: 'stage-plan',
                title: 'Plan · Plan → Implement → Review',
                createdAt: _now,
              ),
            ],
          ),
          overviewPeekChatProvider.overrideWithValue(
            (entry, _) => Text(
              'chat:${entry.id}',
              key: ValueKey('overview-peek-chat:${entry.id}'),
            ),
          ),
        ],
      );
      container.read(pipelinePeekProvider.notifier).open('run-1');
    });
    tearDown(() => container.dispose());

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(520, 1400),
      double textScale = 1,
      bool compact = false,
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(textScale),
              ),
              child: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => switch (ref.watch(
                    pipelinePeekProvider,
                  )) {
                    null => const Text('closed'),
                    final peek => PipelineRunPeek(
                      peek: peek,
                      compact: compact,
                      onClose: ref.read(pipelinePeekProvider.notifier).close,
                    ),
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('every stage, the gate\'s verbs, and each stage\'s answer, '
        'artifacts and hand-off', (tester) async {
      await pump(tester);
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(ValueKey('pipeline-stage:run-1:$i')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('pipeline-approve:run-1')), findsOne);
      expect(find.byKey(const ValueKey('pipeline-stop:run-1')), findsOne);
      expect(
        find.byKey(const ValueKey('pipeline-handoff-text:run-1')),
        findsOne,
      );
      expect(find.byKey(const ValueKey('pipeline-record:0:1')), findsOne);
      expect(find.textContaining('spec.md'), findsWidgets);
      // Its details are the peek; the card offers no second way to them.
      expect(
        find.byKey(const ValueKey('pipeline-details:run-1')),
        findsNothing,
      );
    });

    testWidgets('a stage clicked shows its session\'s chat, and back returns '
        'to the run', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('pipeline-stage:run-1:0')));
      await tester.pumpAndSettle();
      expect(find.text('chat:stage-plan'), findsOneWidget);
      expect(
        container.read(pipelinePeekProvider),
        const PipelinePeek('run-1', stageSessionId: 'stage-plan'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('pipeline-peek-title')))
            .data,
        'Plan',
      );
      await tester.tap(find.byKey(const ValueKey('pipeline-peek-back')));
      await tester.pumpAndSettle();
      expect(find.text('chat:stage-plan'), findsNothing);
      expect(find.byKey(const ValueKey('pipeline-approve:run-1')), findsOne);

      // A stage record's "Open session" shows it here too.
      await tester.ensureVisible(
        find.byKey(const ValueKey('pipeline-open-session:stage-plan')),
      );
      await tester.tap(
        find.byKey(const ValueKey('pipeline-open-session:stage-plan')),
      );
      await tester.pumpAndSettle();
      expect(find.text('chat:stage-plan'), findsOneWidget);
    });

    testWidgets('a stage whose session is not here says so', (tester) async {
      container
          .read(pipelinePeekProvider.notifier)
          .openStage('run-1', 'elsewhere');
      await pump(tester);
      expect(find.textContaining('not on this machine'), findsOneWidget);
    });

    for (final (size, scale) in const [
      (Size(360, 800), 1.0),
      (Size(360, 800), 1.6),
      (Size(520, 900), 1.6),
    ]) {
      testWidgets('it fits ${size.width.toInt()} px at $scale, run and '
          'stage', (tester) async {
        await pump(tester, size: size, textScale: scale, compact: true);
        expect(tester.takeException(), isNull);
        container
            .read(pipelinePeekProvider.notifier)
            .openStage('run-1', 'stage-plan');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('on the board', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ks-run-peek');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold the file; the OS sweeps temp.
      }
    });

    Future<ProviderContainer> board(
      WidgetTester tester, {
      bool phone = false,
    }) => pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      phone: phone,
      size: phone ? const Size(390, 844) : const Size(1440, 900),
      overrides: [
        pipelinesProvider.overrideWith(() => _Runs([_gate()])),
      ],
    );

    testWidgets('a card clicked opens the run beside the board, in place of '
        'a session\'s peek', (tester) async {
      final container = await board(tester);
      container.read(overviewFocusProvider.notifier).peek('ks-r21');
      await settleMission(tester);
      expect(find.byKey(const ValueKey('overview-peek:ks-r21')), findsOne);

      await tester.tap(
        find.byKey(const ValueKey('overview-pipeline-open:run-1')),
      );
      await settleMission(tester);
      expect(find.byKey(const ValueKey('overview-run-peek:run-1')), findsOne);
      expect(find.byKey(const ValueKey('overview-peek:ks-r21')), findsNothing);
      expect(container.read(overviewFocusProvider).peeked, isNull);
      // The board stays beside it.
      expect(find.byKey(const ValueKey('overview-pipeline:run-1')), findsOne);

      // A session's peek takes the place back.
      container.read(overviewFocusProvider.notifier).peek('ks-r21');
      await settleMission(tester);
      expect(container.read(pipelinePeekProvider), isNull);
      expect(
        find.byKey(const ValueKey('overview-run-peek:run-1')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets('on a phone the run is a page of its own', (tester) async {
      final container = await board(tester, phone: true);
      final card = find.byKey(const ValueKey('overview-pipeline-open:run-1'));
      await tester.ensureVisible(card);
      await settleMission(tester);
      await tester.tap(card);
      await settleMission(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('pipeline-peek:run-1')), findsOne);
      expect(
        find.byKey(const ValueKey('overview-run-peek:run-1')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('pipeline-peek-close')));
      await settleMission(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('pipeline-peek:run-1')), findsNothing);
      expect(container.read(pipelinePeekProvider), isNull);
      await unmountMission(tester);
    });

    testWidgets('a gate counts under Needs you, a failed run under Stuck', (
      tester,
    ) async {
      final container = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        overrides: [
          pipelinesProvider.overrideWith(
            () => _Runs([
              _gate(),
              _gate(id: 'run-3').copyWith(state: PipelineRunState.failed),
            ]),
          ),
        ],
      );
      final today = container.read(overviewTodayProvider);
      expect(today.gatesWaiting, 1);
      expect(today.pipelinesFailed, 1);
      expect(today.stuckDetail, contains('1 pipeline failed'));
      await unmountMission(tester);
    });
  });
}
