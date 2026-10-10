import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_today.dart';
import 'package:karmashala/src/features/overview/presentation/overview_pipeline_lane.dart';
import 'package:karmashala/src/features/pipelines/application/pipelines_controller.dart';
import 'package:karmashala_automations/pipelines.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **The Pipelines lane**: a run as one card, its stages a compact flow, the
/// gate's Approve in reach — and its stages' sessions in no other lane.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 9, 12);
  final threeStages = kPipelineTemplates.first;

  PipelineRun gateRun() => PipelineRun(
    id: 'r1',
    definition: threeStages,
    repositoryId: 'r1',
    input: 'Add a badge to the cart icon',
    state: PipelineRunState.waiting,
    byPerson: true,
    createdAt: now.subtract(const Duration(minutes: 5)),
    updatedAt: now,
    records: [
      PipelineStageRecord(
        stageIndex: 0,
        role: 'Plan',
        attempt: 1,
        state: PipelineStageState.approval,
        sessionId: 's-plan',
        answer: 'Plan: a badge, then a test.',
        startedAt: now.subtract(const Duration(minutes: 4)),
        finishedAt: now.subtract(const Duration(minutes: 1)),
      ),
    ],
  );

  PipelineRun runningRun() => PipelineRun(
    id: 'r3',
    definition: threeStages,
    repositoryId: 'r1',
    input: 'Rename the cart',
    state: PipelineRunState.running,
    createdAt: now.subtract(const Duration(minutes: 9)),
    updatedAt: now,
    records: [
      PipelineStageRecord(
        stageIndex: 0,
        role: 'Plan',
        attempt: 1,
        state: PipelineStageState.running,
        sessionId: 's-run',
        startedAt: now.subtract(const Duration(minutes: 8)),
      ),
    ],
  );

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-pipeline-lane');
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.pipelineRows
      ..putRun(gateRun())
      ..putRun(runningRun());
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file; the OS sweeps temp.
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 1200),
    double textScale = 1,
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
            child: const Scaffold(
              body: SingleChildScrollView(child: OverviewPipelineLane()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('each run is one card; the gate is a clear Approve', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('overview-pipeline:r1')), findsOneWidget);
    expect(find.byKey(const ValueKey('overview-pipeline:r3')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('pipeline-stage:r1:$i')), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey('overview-pipeline-approve:r3')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('overview-pipeline-approve:r1')),
    );
    await tester.pumpAndSettle();
    expect(server.pipelineRows.acts, ['approve r1']);
  });

  testWidgets('a stage peeks its session', (tester) async {
    final keep = container.listen(overviewFocusProvider, (_, _) {});
    addTearDown(keep.close);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('pipeline-stage:r3:0')));
    await tester.pumpAndSettle();
    expect(container.read(overviewFocusProvider).peeked, 's-run');
  });

  test('the stages\' sessions are held out of the other lanes', () async {
    container.read(pipelinesProvider);
    await container.read(pipelinesProvider.notifier).refresh();
    expect(container.read(overviewPipelineSessionIdsProvider), {
      's-plan',
      's-run',
    });
  });

  testWidgets(
    'the Board\'s filter narrows the lane: Needs you keeps the gate',
    (tester) async {
      await pump(tester);
      final own = OverviewTodayPart.needsYou.filter;
      container
          .read(overviewPrefsProvider.notifier)
          .setStateFilter(own.columns, own.states);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('overview-pipeline:r1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('overview-pipeline:r3')), findsNothing);
    },
  );

  for (final (size, scale) in [
    (const Size(360, 1600), 1.0),
    (const Size(412, 1600), 1.6),
    (const Size(1440, 1200), 1.6),
  ]) {
    testWidgets('$size at ${scale}x: no overflow', (tester) async {
      await pump(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('overview-pipeline-approve:r1')),
        findsOneWidget,
      );
    });
  }
}
