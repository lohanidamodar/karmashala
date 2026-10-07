import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

void main() {
  var tapped = 0;

  Widget header({List<Widget> controls = const []}) => WorkbenchTabScaffold(
    icon: AppIcons.package,
    title: 'Stores and everything about them',
    controls: controls,
    actions: [
      IconButton(
        tooltip: 'Refresh',
        icon: const Icon(AppIcons.arrowClockwise),
        onPressed: () => tapped++,
      ),
    ],
    body: const Text('the body'),
  );

  Widget picker() => CompactSegmented<int>(
    key: const ValueKey('picker'),
    segments: const [
      ButtonSegment(value: 0, label: Text('24h')),
      ButtonSegment(value: 1, label: Text('7d')),
      ButtonSegment(value: 2, label: Text('30d')),
    ],
    selected: 0,
    onChanged: (_) {},
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1440, 900),
    double textScale = 1,
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light().copyWith(platform: platform),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: app!,
        ),
        // Under the app's Theme, which the builder is not.
        home: Builder(builder: (context) => UiDensity.wrap(context, child)),
      ),
    );
    // A changed theme animates in; its platform flips halfway.
    await tester.pumpAndSettle();
  }

  testWidgets('a titled tab wears the Stores header', (tester) async {
    await pump(tester, header(controls: [picker()]));

    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.toolbarHeight, Chrome.tabAppBar);
    expect(bar.automaticallyImplyLeading, isFalse);
    final glyph = tester.widget<Icon>(find.byIcon(AppIcons.package));
    final scheme = Theme.of(tester.element(find.byType(AppBar))).colorScheme;
    expect(glyph.color, scheme.tertiary);
    expect(find.text('Stores and everything about them'), findsOneWidget);
    // Wide: the picker sits in the bar, beside the name.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const ValueKey('picker')),
      ),
      findsOneWidget,
    );
    expect(find.text('the body'), findsOneWidget);
  });

  testWidgets('under PaneTitleOverride there is no bar, and the controls and '
      'actions sit above the body', (tester) async {
    await pump(
      tester,
      PaneTitleOverride(child: header(controls: [picker()])),
      size: const Size(390, 844),
    );

    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Stores and everything about them'), findsNothing);
    expect(find.byKey(const ValueKey('picker')), findsOneWidget);
    final strip = tester.getBottomLeft(find.byKey(const ValueKey('picker')));
    expect(
      strip.dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('the body')).dy),
    );
    await tester.tap(find.byTooltip('Refresh'));
    expect(tapped, 1);
  });

  testWidgets('at 360px and 1.6x text nothing overflows and the action is '
      'reachable', (tester) async {
    await pump(
      tester,
      header(controls: [picker()]),
      size: const Size(360, 640),
      textScale: 1.6,
    );

    expect(tester.takeException(), isNull);
    // Compact: the picker leaves the bar for the strip.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const ValueKey('picker')),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('picker')), findsOneWidget);
    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.toolbarHeight, greaterThan(Chrome.tabAppBar));
    await tester.tap(find.byTooltip('Refresh'));
    expect(tapped, 1);
  });

  testWidgets('too narrow for its actions, the bar gives them to the strip', (
    tester,
  ) async {
    await pump(
      tester,
      WorkbenchTabScaffold(
        icon: AppIcons.article,
        title: 'Logs',
        actions: [
          for (var i = 0; i < 4; i++)
            IconButton(
              tooltip: 'Action $i',
              icon: const Icon(AppIcons.copy),
              onPressed: () => tapped++,
            ),
        ],
        body: const Text('the body'),
      ),
      size: const Size(240, 600),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Action 3'),
      ),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Action 3'));
    expect(tapped, 1);
  });

  testWidgets('under a thumb the bar is never shorter than a touch app bar', (
    tester,
  ) async {
    await pump(
      tester,
      header(),
      size: const Size(800, 1280),
      platform: TargetPlatform.android,
    );

    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.toolbarHeight, greaterThanOrEqualTo(Touch.appBar));
    final action = tester.getSize(find.byTooltip('Refresh'));
    expect(action.height, greaterThanOrEqualTo(Touch.target));
  });

  testWidgets('the compact picker is compact under a pointer and padded under '
      'a thumb', (tester) async {
    await pump(tester, Scaffold(body: Center(child: picker())));
    final pointer = tester.getSize(find.byKey(const ValueKey('picker')));

    await pump(
      tester,
      Scaffold(body: Center(child: picker())),
      platform: TargetPlatform.android,
    );
    final thumb = tester.getSize(find.byKey(const ValueKey('picker')));
    expect(pointer.height, lessThan(Touch.target));
    expect(thumb.height, greaterThanOrEqualTo(Touch.target));
  });

  testWidgets('the filter funnel shows how many filters are set', (
    tester,
  ) async {
    await pump(
      tester,
      Scaffold(body: FilterFunnelButton(count: 2, onPressed: () => tapped++)),
    );
    expect(find.byTooltip('Filters (2 set)'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byTooltip('Filters (2 set)'));
    expect(tapped, 1);
  });
}
