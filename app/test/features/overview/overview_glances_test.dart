import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/widgets/dashboard_glance.dart';
import 'package:karmashala/src/features/overview/application/overview_glance_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/glances/dashboard_glances.dart';
import 'package:karmashala/src/features/overview/presentation/overview_glances.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// **Glances**: the registry, a tile per glance that opens its page, and
/// hiding, ordering and folding kept per device.
void main() {
  late Directory dir;
  final opened = <String>[];

  setUp(() async {
    opened.clear();
    dir = await Directory.systemTemp.createTemp('ks-glances');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file; the OS sweeps temp.
    }
  });

  DashboardGlance glance(String id) => DashboardGlance(
    id: id,
    title: 'Page $id',
    icon: AppIcons.squaresFour,
    build: (context) => Text(
      GlanceScope.compactOf(context) ? 'one line $id' : 'body of $id',
      key: ValueKey('body:$id'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    onOpen: (_, _) => opened.add(id),
  );

  final glances = [glance('a'), glance('b'), glance('c')];

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        dashboardGlancesProvider.overrideWithValue(glances),
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double scale = 1,
    ProviderContainer? using,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = using ?? container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: UiDensity.wrap(context, child!),
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(Insets.lg),
              child: OverviewGlances(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Finder tile(String id) => find.byKey(ValueKey('overview-glance:$id'));

  Future<void> pickFromMenu(WidgetTester tester, String id, String item) async {
    await tester.tap(find.byKey(ValueKey('overview-glance-menu:$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(item)));
    await tester.pumpAndSettle();
  }

  test('every glance is registered, in its first order', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(
      [for (final g in c.read(dashboardGlancesProvider)) g.id],
      ['todos', 'running', 'stores'],
    );
  });

  test('order, hidden and folded survive a fresh read', () async {
    final c = container();
    final prefs = c.read(glancePrefsProvider.notifier);
    prefs.move('c', -1, ids: ['a', 'b', 'c']);
    prefs.setHidden('a', true);
    prefs.toggleCollapsed('b');
    prefs.setAreaCollapsed(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(arrangedGlanceIds(['a', 'b', 'c'], c.read(glancePrefsProvider)), [
      'a',
      'c',
      'b',
    ]);

    final fresh = container();
    fresh.read(glancePrefsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final kept = fresh.read(glancePrefsProvider);
    expect(kept.hidden, {'a'});
    expect(kept.collapsed, {'b'});
    expect(kept.areaCollapsed, isTrue);
    expect(arrangedGlanceIds(['a', 'b', 'c'], kept), ['a', 'c', 'b']);
  });

  test('a glance added later keeps its registry place after those placed', () {
    const prefs = GlancePrefs(order: ['b', 'a']);
    expect(arrangedGlanceIds(['a', 'b', 'new'], prefs), ['b', 'a', 'new']);
  });

  testWidgets('each tile opens its page; the body is the glance\'s own', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('overview-glances-row')), findsOneWidget);
    expect(find.text('body of b'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-glance-open:b')));
    await tester.pumpAndSettle();
    expect(opened, ['b']);
  });

  testWidgets('hide, move and fold are remembered; hidden ones come back', (
    tester,
  ) async {
    final c = await pump(tester);
    await pickFromMenu(tester, 'a', 'overview-glance-hide');
    expect(tile('a'), findsNothing);
    expect(c.read(glancePrefsProvider).hidden, {'a'});

    await pickFromMenu(tester, 'c', 'overview-glance-move-back');
    expect(
      tester.getTopLeft(tile('c')).dx,
      lessThan(tester.getTopLeft(tile('b')).dx),
    );

    await tester.tap(find.byKey(const ValueKey('overview-glance-fold:b')));
    await tester.pumpAndSettle();
    expect(find.text('body of b'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('overview-glances-hidden')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('overview-glance-show:a')));
    await tester.pumpAndSettle();
    expect(tile('a'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('overview-glances-fold')));
    await tester.pumpAndSettle();
    expect(tile('a'), findsNothing);
    expect(c.read(glancePrefsProvider).areaCollapsed, isTrue);
  });

  for (final width in [360.0, 412.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('${width}px at ${scale}x: a strip of one-line tiles', (
        tester,
      ) async {
        await pump(tester, size: Size(width, 800), scale: scale);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('overview-glances-strip')),
          findsOneWidget,
        );
        expect(find.text('one line a'), findsOneWidget);
        // One row: no taller than a touch row and a little.
        expect(
          tester.getSize(tile('a')).height,
          lessThanOrEqualTo(Touch.target * scale + Insets.xs),
        );
      });
    }
  }

  for (final scale in [1.0, 1.6]) {
    testWidgets('desktop at ${scale}x: tiles side by side, no overflow', (
      tester,
    ) async {
      await pump(tester, scale: scale);
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(tile('b')).dy, tester.getTopLeft(tile('a')).dy);
    });
  }

  // The registered glances themselves — other pages' too, once added — in
  // the area, with nothing read yet: their empty and loading states.
  for (final (size, scale) in [
    (const Size(360, 800), 1.0),
    (const Size(360, 800), 1.6),
    (const Size(1440, 900), 1.0),
    (const Size(1440, 900), 1.6),
  ]) {
    testWidgets('${size.width}px at ${scale}x: every registered glance draws', (
      tester,
    ) async {
      final c = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      await pump(tester, size: size, scale: scale, using: c);
      expect(tester.takeException(), isNull);
      final compact = size.width < 600;
      for (final g in c.read(dashboardGlancesProvider)) {
        await tester.ensureVisible(tile(g.id));
        await tester.pumpAndSettle();
        expect(tile(g.id), findsOneWidget, reason: g.id);
        expect(
          find.byKey(ValueKey('overview-glance-body:${g.id}')),
          findsOneWidget,
          reason: g.id,
        );
        if (compact) {
          // One row on a phone's strip, whatever the glance draws.
          expect(
            tester.getSize(tile(g.id)).height,
            lessThanOrEqualTo(Touch.target * scale + Insets.xs),
            reason: g.id,
          );
        }
      }
      expect(tester.takeException(), isNull);
      // No server here: a page's read retries until its container goes.
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
