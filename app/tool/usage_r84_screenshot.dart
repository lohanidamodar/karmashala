// Renders the Usage tab and the Usage glance (round 84) over fake readings
// into PNGs: desktop and phone, text scale 1.0 and 1.6, light and dark.
// Nothing reads a real account. Lives under tool/ so `flutter test` never
// picks it up:
//
//   flutter test tool/usage_r84_screenshot.dart
//
// Images land in build/usage-r84-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/usage_session_tokens.dart';
import 'package:karmashala/src/features/agents/presentation/usage_glance.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_tab_view.dart';
import 'package:karmashala/src/features/sessions/application/capacity_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../test/features/agents/usage_fixtures.dart';
import '../test/support/fakes.dart';
import '../test/support/fixtures.dart';

const _outDir = 'build/usage-r84-screenshots';

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

final _capacity = CapacitySnapshot(
  limits: const LaunchLimits(global: 4, machines: {'windows': 2}),
  running: 3,
  scopes: const [
    CapacityScopeUse(
      scope: CapacityScope.global,
      key: '',
      label: 'All',
      used: 3,
      limit: 4,
    ),
    CapacityScopeUse(
      scope: CapacityScope.machine,
      key: 'windows',
      label: 'Windows',
      used: 2,
      limit: 2,
    ),
  ],
  waiters: [
    LaunchWaiter(
      ticketId: 't1',
      label: 'Nightly triage',
      priority: LaunchPriority.background,
      place: 1,
      reason: 'Waiting for a slot',
      enqueuedAt: testTime,
    ),
  ],
);

final _rows = [
  UsageSessionRow(
    sessionId: 's1',
    title: 'Fix the checkout flow',
    project: 'karmashala',
    agentId: 'claudeCode',
    tokens: 2400000,
    tokensByModel: const {'claude-opus-5-5': 2400000},
    lastActivityAt: testTime.subtract(const Duration(minutes: 12)),
  ),
  UsageSessionRow(
    sessionId: 's2',
    title: 'Translate the store listing',
    project: 'site',
    agentId: 'opencode',
    tokens: 310000,
    costAmount: 1.84,
    costCurrency: 'USD',
    lastActivityAt: testTime.subtract(const Duration(minutes: 40)),
  ),
  UsageSessionRow(
    sessionId: 's3',
    title: 'Review the release notes',
    project: 'karmashala',
    agentId: 'opencode',
    tokens: 90000,
    costAmount: 0.42,
    costCurrency: 'USD',
    lastActivityAt: testTime.subtract(const Duration(hours: 1)),
  ),
];

void main() {
  setUpAll(() async {
    Directory(_outDir).createSync(recursive: true);
    await _loadFonts();
  });

  Future<ProviderContainer> container() async {
    final db = seedUsageDatabase();
    seedUsage(db.server, agentInstallation(), usage: usageSnapshot());
    // A steady recent pace: 24 points an hour, ending at the reading's 62%,
    // and a day of earlier readings.
    for (var i = 60; i >= 1; i--) {
      final at = testTime.subtract(Duration(minutes: 5 * i));
      db.server.usageRows.insert(
        UsageSample(
          accountKey: 'claudeCode@windows',
          windowLabel: '5-hour',
          span: kUsageFiveHourWindow,
          percent: i > 12 ? 14 + (60 - i) * 0.2 : 62.0 - 2 * i,
          recordedAt: at,
        ),
      );
    }
    return ProviderContainer(
      overrides: [
        await db.server.override(),
        clockProvider.overrideWithValue(MovableClock(testTime)),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            features: {'sessions.capacity', 'sessions.stats'},
          ),
        ),
        capacityNowProvider.overrideWithValue(_capacity),
        usageSessionRowsProvider.overrideWith((ref) async => _rows),
      ],
    );
  }

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    required Widget home,
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await tester.runAsync(container);
    addTearDown(c!.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
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
            home: Scaffold(body: home),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Durations.short2));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  for (final (width, height) in const [(1440.0, 2200.0), (360.0, 3600.0)]) {
    for (final scale in const [1.0, 1.6]) {
      for (final brightness in Brightness.values) {
        testWidgets('tab $width $scale $brightness', (tester) async {
          await shoot(
            tester,
            'usage-tab-${width.toInt()}-x$scale-${brightness.name}',
            size: Size(width, height * (scale > 1 ? 1.5 : 1)),
            home: const UsageTabView(),
            brightness: brightness,
            textScale: scale,
          );
        });
      }
    }
  }

  for (final scale in const [1.0, 1.6]) {
    testWidgets('glance $scale', (tester) async {
      await shoot(
        tester,
        'usage-glance-x$scale',
        size: const Size(320, 200),
        home: const Padding(
          padding: EdgeInsets.all(Insets.md),
          child: UsageGlance(),
        ),
        textScale: scale,
      );
    });
  }
}
