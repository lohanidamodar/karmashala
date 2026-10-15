import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/overview/timeline/application/timeline_controller.dart';
import 'package:karmashala/src/features/overview/timeline/data/timeline_data.dart';
import 'package:karmashala/src/features/overview/timeline/presentation/overview_timeline_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala/src/features/overview/timeline/presentation/timeline_painters.dart';
import 'package:karmashala_ui/tokens.dart' show Chrome, Insets, TypeSizes;

class _FakeTimelineData implements TimelineData {
  final List<ActivityEntry> entries = [];
  final List<({DateTime from, DateTime to, List<String>? projects})> asked = [];
  final StreamController<List<ActivityEntry>> live = StreamController.broadcast(
    sync: true,
  );
  Object? refusal;

  @override
  Stream<List<ActivityEntry>> get appended => live.stream;

  @override
  Future<List<ActivityEntry>> range({
    required DateTime from,
    required DateTime to,
    List<String>? projectIds,
  }) async {
    asked.add((from: from, to: to, projects: projectIds));
    if (refusal case final refusal?) throw refusal;
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
    String machine = 'win',
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
    machine: machine,
  );

  // The lanes open on what the seeded day did, padded a quarter hour each
  // side: 08:45 to 16:15.
  double xAt(Rect lane, num hours) {
    final width = lane.width - Chrome.timelineGutter - Insets.lg;
    return lane.left + Chrome.timelineGutter + (hours - 8.75) / 7.5 * width;
  }

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
      e(
        ActivityKind.sessionStarted,
        13,
        session: 'b1',
        project: 'p2',
        machine: 'mac',
      ),
      e(
        ActivityKind.turnStarted,
        13.5,
        session: 'b1',
        project: 'p2',
        machine: 'mac',
      ),
      e(ActivityKind.sessionStarted, 14, session: 'gone', project: 'p2'),
      e(ActivityKind.deleted, 15, session: 'gone', project: 'p2'),
    ]);
  }

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
    Set<String>? features,
    VoidCallback? onUpdateServer,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (features != null)
            serverOfferProvider.overrideWithValue(
              ServerOffer(sameMachine: false, features: features),
            ),
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
              onUpdateServer: onUpdateServer,
              clock: () => h(16),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  for (final (name, size, scale) in [
    ('360 px at 1.6x', const Size(360, 780), 1.6),
    ('desktop', const Size(1440, 900), 1.0),
  ]) {
    testWidgets('a server older than the activity log says so, with a way to '
        'Settings → Server ($name)', (tester) async {
      data.refusal = const DataRefused.invalid(
        'unknown request kind activity.range',
      );
      var updates = 0;
      await pump(
        tester,
        size,
        textScale: scale,
        features: const {'sessions.transcript'},
        onUpdateServer: () => updates++,
      );
      expect(
        find.text(
          "This server is older than the app and can't show the Timeline. "
          'Update the server in Settings → Server.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('DataRefused'), findsNothing);
      expect(find.textContaining('activity.range'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('timeline-update-server')));
      expect(updates, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a server that offers the activity log still names a failure', (
    tester,
  ) async {
    data.refusal = const DataRefused(
      DataRefusalCode.failed,
      'the log is locked',
    );
    await pump(
      tester,
      const Size(1440, 900),
      features: const {ActivityRange.feature},
    );
    expect(find.byKey(const ValueKey('timeline-error')), findsOneWidget);
    expect(find.textContaining('the log is locked'), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-update-server')), findsNothing);
  });

  testWidgets('the desktop lanes at 1440x900: projects as groups, a lane per '
      'session, and a click shows what it did beside them', (tester) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('timeline-chart')), findsOneWidget);
    expect(find.textContaining('Alpha · 2 sessions'), findsOneWidget);
    expect(find.textContaining('Beta · 2 sessions · 1 live'), findsOneWidget);
    for (final id in ['s1', 'child', 'b1', 'gone']) {
      expect(find.byKey(ValueKey('timeline-lane-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('timeline-avatar-$id')), findsOneWidget);
    }
    expect(find.text('Waiting on you'), findsOneWidget, reason: 'the legend');

    final box = tester.getRect(find.byKey(const ValueKey('timeline-lane-s1')));
    await tester.tapAt(Offset(xAt(box, 10.5), box.center.dy));
    await tester.pump();
    expect(opened, isEmpty, reason: 'a click shows it; Open opens it');
    expect(find.byKey(const ValueKey('timeline-detail-s1')), findsOneWidget);
    expect(
      find.textContaining('Waiting on you 12m (asked to allow write'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline-detail-relative-child')),
      findsOneWidget,
    );
    // Docked beside the lanes, not over them.
    expect(
      tester.getRect(find.byKey(const ValueKey('timeline-detail-s1'))).left,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('timeline-lane-s1'))).right,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('timeline-detail-open')));
    expect(opened, ['s1']);

    // A deleted session shows what it did but has nothing to open.
    final gone = tester.getRect(
      find.byKey(const ValueKey('timeline-lane-gone')),
    );
    await tester.tapAt(Offset(xAt(gone, 14.5), gone.center.dy));
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-detail-gone')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-detail-open')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('timeline-detail-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-detail-gone')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lane carries its title, the times and how long it kept the '
      'owner waiting, painted on the lane', (tester) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byKey(const ValueKey('timeline-lane-s1')),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((w) => w.painter)
        .whereType<TimelineRowPainter>()
        .single;
    expect(painter.session.title, 'Session s1');
    expect(painter.session.waitingTotal, const Duration(minutes: 12));
    expect(painter.waitsOnly, isFalse);

    await tester.tap(find.byKey(const ValueKey('timeline-waits-only')));
    await tester.pump();
    final dimmed = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<TimelineRowPainter>();
    expect(dimmed, isNotEmpty);
    expect(dimmed.every((p) => p.waitsOnly), isTrue);
  });

  testWidgets('the search and the machine filter narrow the lanes', (
    tester,
  ) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    await tester.enterText(find.byKey(const ValueKey('timeline-search')), 'b1');
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-lane-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-lane-s1')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('timeline-search')), '');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('timeline-projects')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline-machine-mac')));
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-lane-b1')), findsNothing);
    expect(find.byKey(const ValueKey('timeline-lane-s1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Week asks for the seven days ending on the day shown', (
    tester,
  ) async {
    seedDay();
    await pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Week'));
    await tester.pump();
    await tester.pump();
    expect(data.asked.last.from, DateTime(2026, 9, 30).toUtc());
    expect(data.asked.last.to, DateTime(2026, 10, 7).toUtc());
    await tester.tap(find.text('Day'));
    await tester.pump();
    await tester.pump();
    expect(data.asked.last.from, dayStart.toUtc());
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
    await mouse.moveTo(Offset(xAt(box, 10.1), box.center.dy));
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

  for (final (name, size, scale) in [
    ('390x844', const Size(390, 844), 1.0),
    ('360 px at 1.6x', const Size(360, 780), 1.6),
  ]) {
    testWidgets('the phone at $name: the same lanes on the last hours, and a '
        'tap shows what it did in a sheet', (tester) async {
      seedDay();
      await pump(tester, size, textScale: scale);
      expect(find.byKey(const ValueKey('timeline-chart')), findsOneWidget);
      for (final id in ['s1', 'child', 'b1', 'gone']) {
        expect(find.byKey(ValueKey('timeline-lane-$id')), findsOneWidget);
      }
      // Zoom is a pinch here; search lives in the filters.
      expect(find.byKey(const ValueKey('timeline-zoom-in')), findsNothing);
      expect(find.byKey(const ValueKey('timeline-search')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('timeline-lane-s1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timeline-detail-s1')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('timeline-detail-open')),
      );
      await tester.tap(find.byKey(const ValueKey('timeline-detail-open')));
      expect(opened, ['s1']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a phone finds a session by name in the filters', (tester) async {
    seedDay();
    await pump(tester, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('timeline-projects')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('timeline-search')), 'b1');
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-lane-s1')), findsNothing);
    expect(find.byKey(const ValueKey('timeline-lane-b1')), findsOneWidget);
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
