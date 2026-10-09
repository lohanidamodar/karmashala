// Renders round 82's dashboard — Today, glances, a Pipelines lane, a
// Waiting for a slot lane and a batch selection — on a desktop and at 390 px.
// Under tool/ so `flutter test` never picks it up; run it from app/:
//
//   flutter test tool/overview_r82_screenshot.dart
//
// Images land in build/overview-r82-shots/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_batch.dart';
import 'package:karmashala/src/features/pipelines/application/pipelines_controller.dart';
import 'package:karmashala/src/features/running/application/running_glance.dart';
import 'package:karmashala/src/features/sessions/application/capacity_providers.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';

import '../test/features/overview/mission_fixture.dart';

const _outDir = 'build/overview-r82-shots';

Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

final _now = MissionFixture.now;

class _Runs extends PipelinesController {
  @override
  PipelinesState build() => PipelinesState(
    loaded: true,
    runs: {
      'run-1': PipelineRun(
        id: 'run-1',
        definition: kPipelineTemplates.first,
        repositoryId: 'r-p-ks',
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
            answer: 'A badge on the icon, then a widget test.',
            startedAt: _now.subtract(const Duration(minutes: 11)),
            finishedAt: _now.subtract(const Duration(minutes: 2)),
          ),
        ],
      ),
    },
  );
}

class _Todos extends TodosController {
  @override
  List<Todo> build() => [
    for (final (i, body) in [
      'Review round 83 Stores glance',
      'Ship 1.32 to TestFlight',
      'Reply to the cart-badge issue',
      'Clear stale worktrees',
    ].indexed)
      Todo(
        id: 't$i',
        body: body,
        position: i,
        createdAt: _now.subtract(Duration(hours: i)),
      ),
  ];
}

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    bool phone = false,
    double textScale = 1,
  }) async {
    final key = GlobalKey();
    final c = await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: Directory.systemTemp.createTempSync('ks-overview-r82-shot'),
      size: size,
      phone: phone,
      textScale: textScale,
      boundary: key,
      overrides: [
        pipelinesProvider.overrideWith(_Runs.new),
        todosProvider.overrideWith(_Todos.new),
        runningGlanceProvider.overrideWithValue(
          const RunningGlance(
            servers: 3,
            newest: RunningGlanceServer(label: 'vite', port: 5173),
          ),
        ),
        capacityNowProvider.overrideWithValue(
          CapacitySnapshot(
            limits: const LaunchLimits(global: 4),
            running: 4,
            waiters: [
              LaunchWaiter(
                ticketId: 'w1',
                label: 'Fix the flaky cart test',
                priority: LaunchPriority.interactive,
                place: 1,
                reason: 'Waiting for a slot: 4 of 4 are busy',
                enqueuedAt: _now.subtract(const Duration(minutes: 3)),
                personStarted: true,
              ),
            ],
          ),
        ),
      ],
    );
    c.read(overviewSelectionProvider.notifier).selectAll(['ks-r21', 'ks-r32']);
    await settleMission(tester);
    await tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  }

  testWidgets(
    'desktop',
    (t) => shoot(t, 'r82-desktop', size: const Size(1440, 1100)),
  );
  testWidgets(
    'desktop, text 1.6',
    (t) => shoot(
      t,
      'r82-desktop-text160',
      size: const Size(1440, 1100),
      textScale: 1.6,
    ),
  );
  testWidgets(
    '390',
    (t) => shoot(t, 'r82-390', size: const Size(390, 844), phone: true),
  );
  testWidgets(
    '390, text 1.6',
    (t) => shoot(
      t,
      'r82-390-text160',
      size: const Size(390, 844),
      phone: true,
      textScale: 1.6,
    ),
  );
}
