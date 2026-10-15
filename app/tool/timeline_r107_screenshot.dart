// Renders the dashboard's Timeline (round 107) over a realistic fake day into
// PNGs: desktop, tablet and phone, text scale 1.0 and 1.6, light and dark.
// Nothing reads a real server. Lives under tool/ so `flutter test` never
// picks it up:
//
//   flutter test tool/timeline_r107_screenshot.dart
//
// Images land in build/timeline-r107-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/timeline/application/timeline_controller.dart';
import 'package:karmashala/src/features/overview/timeline/data/timeline_data.dart';
import 'package:karmashala/src/features/overview/timeline/presentation/overview_timeline_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

const _outDir = 'build/timeline-r107-screenshots';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final asset in assets) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }

  await load(kBundledSansFamily, [
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'packages/karmashala_ui/fonts/Geist-$weight.ttf',
  ]);
  await load(kBundledMonoFamily, [
    'packages/karmashala_ui/fonts/JetBrainsMono-Regular.ttf',
  ]);
  await load('packages/picons/PhosphorRegular', [
    'packages/picons/lib/fonts/Phosphor.ttf',
  ]);
  await load('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']);
  await load('packages/picons/PhosphorFill', [
    'packages/picons/lib/fonts/Phosphor-Fill.ttf',
  ]);
}

class _FakeTimelineData implements TimelineData {
  _FakeTimelineData(this.entries);

  final List<ActivityEntry> entries;

  @override
  Stream<List<ActivityEntry>> get appended => const Stream.empty();

  @override
  Future<List<ActivityEntry>> range({
    required DateTime from,
    required DateTime to,
    List<String>? projectIds,
  }) async => [
    for (final e in entries)
      if (!e.at.isBefore(from) &&
          e.at.isBefore(to) &&
          (projectIds?.contains(e.projectId) ?? true))
        e,
  ];
}

final _day = DateTime(2026, 10, 15);
DateTime _h(num hours) =>
    _day.add(Duration(minutes: (hours * 60).round())).toUtc();
final _now = _h(16 + 20 / 60);

const _projects = {
  'ks': 'karmashala',
  'site': 'popupbits-site',
  'api': 'store-api',
};

/// One session's day: `(hour, kind, detail)` after its start.
List<ActivityEntry> _session(
  String id,
  String title,
  String project,
  num start,
  List<(num, ActivityKind, String?)> events, {
  String? parent,
  String agent = 'claudeCode',
  String machine = 'windows',
}) {
  var n = 0;
  ActivityEntry e(num at, ActivityKind kind, [String? detail]) => ActivityEntry(
    id: id.hashCode * 100 + n++,
    at: _h(at),
    kind: kind,
    sessionId: id,
    source: 'live',
    title: title,
    projectId: project,
    projectName: _projects[project],
    agent: agent,
    machine: machine,
    parentSessionId: parent,
    detail: detail,
  );
  return [
    e(start, ActivityKind.sessionStarted),
    if (parent != null) e(start, ActivityKind.linked),
    for (final (at, kind, detail) in events) e(at, kind, detail),
  ];
}

const _t = ActivityKind.turnStarted;
const _te = ActivityKind.turnEnded;
const _w = ActivityKind.waitBegan;
const _we = ActivityKind.waitEnded;
const _end = ActivityKind.sessionEnded;

final _entries = <ActivityEntry>[
  ..._session('r107', 'Round 107 · Timeline redesign', 'ks', 8.5, [
    (8.6, _t, null),
    (9.4, _w, 'pick a design direction'),
    (10.1, _we, null),
    (11.8, _te, null),
    (13.2, _t, null),
    (15.9, _w, 'approve the plan'),
  ]),
  ..._session(
    'r107a',
    'Research timeline prior art',
    'ks',
    8.7,
    [(8.7, _t, null), (9.3, _te, null), (9.35, _end, null)],
    parent: 'r107',
    agent: 'codex',
  ),
  ..._session('r107b', 'Probe the old timeline', 'ks', 10.2, [
    (10.2, _t, null),
    (10.9, _w, 'allow write to app/build'),
    (11.0, _we, null),
    (11.6, _te, null),
    (11.7, _end, null),
  ], parent: 'r107'),
  ..._session('r107c', 'Build the swimlanes', 'ks', 13.3, [
    (13.3, _t, null),
    (14.6, ActivityKind.limitPaused, '5-hour limit'),
    (15.1, ActivityKind.limitResumed, null),
  ], parent: 'r107'),
  ..._session('r106', 'Round 106 · Dashboard asks', 'ks', 6.0, [
    (6.1, _t, null),
    (7.2, _w, 'answer: keep the dock?'),
    (8.05, _we, null),
    (9.0, _te, null),
    (9.2, _end, null),
  ]),
  ..._session(
    'fix1',
    'Fix flaky charts test',
    'ks',
    12.0,
    [(12.05, _t, null), (12.6, _te, null), (12.7, _end, null)],
    agent: 'gemini',
    machine: 'archlinux',
  ),
  ..._session(
    'site1',
    'Landing page copy',
    'site',
    7.5,
    [
      (7.6, _t, null),
      (8.3, _te, null),
      (9.5, _t, null),
      (10.4, _w, 'choose a headline'),
      (12.9, _we, null),
      (13.6, _te, null),
    ],
    agent: 'codex',
    machine: 'mac-mini',
  ),
  ..._session(
    'site2',
    'Pricing table',
    'site',
    14.0,
    [(14.05, _t, null), (15.2, _te, null), (15.4, _t, null)],
    agent: 'codex',
    machine: 'mac-mini',
  ),
  ..._session('api1', 'Receipt validation', 'api', 9.0, [
    (9.1, _t, null),
    (10.0, _te, null),
    (11.0, _t, null),
    (11.3, _w, 'run migrations?'),
    (11.45, _we, null),
    (12.4, _te, null),
    (12.5, _end, null),
  ], machine: 'build-box'),
  ..._session(
    'api1a',
    'Write receipt tests',
    'api',
    11.5,
    [(11.5, _t, null), (12.2, _te, null), (12.25, _end, null)],
    parent: 'api1',
    agent: 'codex',
    machine: 'build-box',
  ),
  ..._session('api2', 'Webhook retries', 'api', 14.5, [
    (14.6, _t, null),
    (15.6, _w, 'allow network to stripe.test'),
  ], machine: 'build-box'),
];

void main() {
  setUpAll(() async {
    Directory(_outDir).createSync(recursive: true);
    await _loadFonts();
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    Brightness brightness = Brightness.dark,
    double textScale = 1,
    String? select,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineDataProvider.overrideWithValue(_FakeTimelineData(_entries)),
          timelineProjectChoicesProvider.overrideWithValue([
            for (final MapEntry(:key, :value) in _projects.entries)
              (id: key, name: value),
          ]),
          timelineRangeProvider.overrideWith(
            () => TimelineRangeController(() => _day),
          ),
        ],
        child: RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(body: OverviewTimelineView(clock: () => _now)),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Durations.short2));
    await tester.pump();
    await tester.pump(Durations.short2);
    if (select != null) {
      await tester.tap(find.byKey(ValueKey('timeline-lane-$select')));
      await tester.pump();
      await tester.pump(Durations.long2);
    }
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  for (final (width, height) in const [
    (1440.0, 900.0),
    (900.0, 800.0),
    (360.0, 780.0),
  ]) {
    for (final scale in const [1.0, 1.6]) {
      for (final brightness in Brightness.values) {
        testWidgets('timeline $width $scale $brightness', (tester) async {
          await shoot(
            tester,
            'timeline-${width.toInt()}-x$scale-${brightness.name}',
            size: Size(width, height),
            brightness: brightness,
            textScale: scale,
          );
        });
      }
    }
  }

  for (final (width, height) in const [(1440.0, 900.0), (360.0, 780.0)]) {
    for (final brightness in Brightness.values) {
      testWidgets('detail $width $brightness', (tester) async {
        await shoot(
          tester,
          'timeline-detail-${width.toInt()}-${brightness.name}',
          size: Size(width, height),
          brightness: brightness,
          select: 'r107',
        );
      });
    }
  }
}
