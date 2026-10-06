import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/timeline/application/timeline_controller.dart';
import 'package:karmashala/src/features/overview/timeline/data/timeline_data.dart';
import 'package:karmashala/src/features/overview/timeline/presentation/overview_timeline_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/tokens.dart' show TypeSizes;

class _FakeTimelineData implements TimelineData {
  final List<ActivityEntry> entries = [];
  final List<({DateTime from, DateTime to, List<String>? projects})> asked = [];
  final StreamController<List<ActivityEntry>> live = StreamController.broadcast(
    sync: true,
  );

  @override
  Stream<List<ActivityEntry>> get appended => live.stream;

  @override
  Future<List<ActivityEntry>> range({
    required DateTime from,
    required DateTime to,
    List<String>? projectIds,
  }) async {
    asked.add((from: from, to: to, projects: projectIds));
    return [
      for (final e in entries)
        if (!e.at.isBefore(from) &&
            e.at.isBefore(to) &&
            (projectIds?.contains(e.projectId) ?? true))
          e,
    ];
  }
}

void main() {
  // A fixed local day, so the range never straddles a real midnight.
  final dayStart = DateTime(2026, 10, 6);
  DateTime h(num hours) =>
      dayStart.add(Duration(minutes: (hours * 60).round())).toUtc();
  var ids = 0;

  ActivityEntry e(
    ActivityKind kind,
    num hours, {
    String session = 's1',
    String project = 'p1',
    String? parent,
    String? detail,
    String? title,
  }) => ActivityEntry(
    id: ++ids,
    at: h(hours),
    kind: kind,
    sessionId: session,
    source: 'live',
    title: title ?? 'Session $session',
    projectId: project,
    projectName: project == 'p1' ? 'Alpha' : 'Beta',
    parentSessionId: parent,
    detail: detail,
  );

  late _FakeTimelineData data;
  late List<String> opened;

  setUp(() {
    data = _FakeTimelineData();
    opened = [];
  });

  void seedDay() {
    data.entries.addAll([
      e(ActivityKind.sessionStarted, 9),
      e(ActivityKind.turnStarted, 9.5),
      e(ActivityKind.waitBegan, 10, detail: 'allow write to app/lib/main.dart'),
      e(ActivityKind.waitEnded, 10.2),
      e(ActivityKind.turnEnded, 11),
      e(ActivityKind.sessionEnded, 12),
      e(ActivityKind.sessionStarted, 10.5, session: 'child', parent: 's1'),
      e(ActivityKind.linked, 10.5, session: 'child', parent: 's1'),
      e(ActivityKind.turnStarted, 10.5, session: 'child'),
      e(ActivityKind.turnEnded, 11.5, session: 'child'),
      e(ActivityKind.sessionStarted, 13, session: 'b1', project: 'p2'),
      e(ActivityKind.turnStarted, 13.5, session: 'b1', project: 'p2'),
      e(ActivityKind.sessionStarted, 14, session: 'gone', project: 'p2'),
      e(ActivityKind.deleted, 15, session: 'gone', project: 'p2'),
    ]);
  }

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineDataProvider.overrideWithValue(data),
          timelineProjectChoicesProvider.overrideWithValue(const [
            (id: 'p1', name: 'Alpha'),
            (id: 'p2', name: 'Beta'),
          ]),
          timelineRangeProvider.overrideWith(
            () => TimelineRangeController(() => dayStart),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: OverviewTimelineView(
              onOpenSession: opened.add,
              clock: () => h(16),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the desktop chart at 1440x900: projects as rows, a bar per '
      'session, and a click opens it', (tester) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('timeline-chart')), findsOneWidget);
    expect(find.textContaining('Alpha · 2 sessions'), findsOneWidget);
    expect(find.textContaining('Beta · 2 sessions'), findsOneWidget);
    for (final id in ['s1', 'child', 'b1', 'gone']) {
      expect(find.byKey(ValueKey('timeline-lane-$id')), findsOneWidget);
    }
    expect(find.text('Waiting on you'), findsOneWidget, reason: 'the legend');

    final lane = find.byKey(const ValueKey('timeline-lane-s1'));
    final box = tester.getRect(lane);
    // 10:30, inside the turn, on the bar past the label column.
    await tester.tapAt(
      Offset(box.left + 240 + (10.5 / 24) * (box.width - 240), box.center.dy),
    );
    expect(opened, ['s1']);

    // A deleted session draws but opens nothing.
    final gone = tester.getRect(
      find.byKey(const ValueKey('timeline-lane-gone')),
    );
    await tester.tapAt(
      Offset(
        gone.left + 240 + (14.5 / 24) * (gone.width - 240),
        gone.center.dy,
      ),
    );
    expect(opened, ['s1']);
  });

  for (final scale in const [1.0, 1.3, 1.6]) {
    testWidgets('the time axis is tall enough for its labels at text scale '
        '$scale', (tester) async {
      seedDay();
      await pump(tester, const Size(1440, 900), textScale: scale);
      final axis = tester.getSize(find.byKey(const ValueKey('timeline-axis')));
      final label = (TextPainter(
        text: const TextSpan(
          text: 'Mon 30',
          style: TextStyle(
            fontSize: TypeSizes.caption,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.linear(scale),
      )..layout()).height;
      // The label from the top, then room for the tick and the "now" dot.
      expect(axis.height, greaterThanOrEqualTo(2 + label + 4 + 6));
    });
  }

  testWidgets('hovering a wait says how long and what was asked', (
    tester,
  ) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    final box = tester.getRect(find.byKey(const ValueKey('timeline-lane-s1')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      Offset(box.left + 240 + (10.1 / 24) * (box.width - 240), box.center.dy),
    );
    await tester.pump();
    expect(
      find.text(
        'Session s1: waiting on you 12m (asked to allow write to '
        'app/lib/main.dart)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a bar tells a screen reader what it was doing', (tester) async {
    seedDay();
    final semantics = tester.ensureSemantics();
    await pump(tester, const Size(1440, 900));
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Session s1, Alpha, .*waiting on you 12m'),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('a child is grouped under its parent and folds away', (
    tester,
  ) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    final parent = tester.getRect(
      find.byKey(const ValueKey('timeline-lane-s1')),
    );
    final child = tester.getRect(
      find.byKey(const ValueKey('timeline-lane-child')),
    );
    expect(child.top, parent.bottom);
    await tester.tap(find.bySemanticsLabel('Hide what Session s1 started'));
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-lane-child')), findsNothing);
  });

  testWidgets('the next and previous day are asked for', (tester) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    expect(data.asked.last.from, dayStart.toUtc());
    await tester.tap(find.byKey(const ValueKey('timeline-next')));
    await tester.pump();
    await tester.pump();
    expect(data.asked.last.from, DateTime(2026, 10, 7).toUtc());
    expect(data.asked.last.to, DateTime(2026, 10, 8).toUtc());
    expect(find.byKey(const ValueKey('timeline-empty')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline-previous')));
    await tester.tap(find.byKey(const ValueKey('timeline-previous')));
    await tester.pump();
    await tester.pump();
    expect(data.asked.last.from, DateTime(2026, 10, 5).toUtc());
  });

  testWidgets('an entry the server appends draws at once', (tester) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('timeline-lane-new')), findsNothing);
    data.live.add([e(ActivityKind.sessionStarted, 15.5, session: 'new')]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-lane-new')), findsOneWidget);
    // One outside the range is not this view's.
    data.live.add([e(ActivityKind.sessionStarted, 30, session: 'tomorrow')]);
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-lane-tomorrow')), findsNothing);
  });

  testWidgets('a project left out is not asked for', (tester) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    await tester.tap(find.byKey(const ValueKey('timeline-projects')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline-project-p2')).last);
    await tester.pump();
    await tester.pump();
    expect(data.asked.last.projects, ['p1']);
    expect(find.byKey(const ValueKey('timeline-lane-b1')), findsNothing);
  });

  testWidgets('the phone list at 390x844: the day\'s sessions, each with a '
      'compact bar', (tester) async {
    seedDay();
    await pump(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey('timeline-chart')), findsNothing);
    expect(find.byKey(const ValueKey('timeline-phone-list')), findsOneWidget);
    expect(find.text('Session s1'), findsOneWidget);
    expect(find.textContaining('waited 12m'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline-phone-s1')));
    expect(opened, ['s1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 150-session day of thousands of turns builds, and builds '
      'only the lanes on screen', (tester) async {
    for (var s = 0; s < 150; s++) {
      final project = s.isEven ? 'p1' : 'p2';
      data.entries.add(
        e(
          ActivityKind.sessionStarted,
          (s % 20) * 0.5,
          session: 'x$s',
          project: project,
        ),
      );
      for (var t = 0; t < 20; t++) {
        final at = (s % 20) * 0.5 + t * 0.15;
        data.entries
          ..add(
            e(ActivityKind.turnStarted, at, session: 'x$s', project: project),
          )
          ..add(
            e(
              ActivityKind.turnEnded,
              at + 0.1,
              session: 'x$s',
              project: project,
            ),
          );
      }
    }
    final watch = Stopwatch()..start();
    await pump(tester, const Size(1440, 900));
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    final built = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('timeline-lane-'),
    );
    expect(built.evaluate().length, inInclusiveRange(10, 60));
    expect(tester.takeException(), isNull);
  });
}
