import 'package:agent_cli/process.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_device_pane/pane.dart';
import 'package:karmashala_device_pane/ports.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/widgets.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/fake_command_runner.dart';
import 'support/fakes.dart';

/// **The device list is one column.** With nothing connected the pane drew
/// emulators as rows with a text Start floating after the name, simulators as
/// a dropdown beside a filled Start, one option as a switch and the other as a
/// checkbox, and four different left edges. These hold the list to one row,
/// one control, one left edge and one right edge.
const _longAvd = 'Sanskrit_Screens_Pixel_Tablet_API_35';

const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'posix', path: '/sdk'),
  adb: EnvironmentPath(environmentId: 'posix', path: '/sdk/platform-tools/adb'),
  emulator: EnvironmentPath(
    environmentId: 'posix',
    path: '/sdk/emulator/emulator',
  ),
);

IosSimulator _sim(String udid, String name) => IosSimulator(
  udid: udid,
  name: name,
  state: SimulatorState.shutdown,
  runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
  deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
  isAvailable: true,
);

Future<void> _pump(
  WidgetTester tester, {
  double width = 320,
  double textScale = 1.0,
  List<IosSimulator>? simulators,
}) async {
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final runner = FakeCommandRunner(processFactory: (_) => FakeProcessHandle());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceCommandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
        deviceClockProvider.overrideWithValue(FixedClock(testTime)),
        androidSdkProvider.overrideWith((ref) async => _sdk),
        androidEmulatorArgumentsProvider.overrideWithValue(const []),
        androidSlimmingServiceProvider.overrideWithValue(null),
        devicesProvider.overrideWith((ref) async => const []),
        avdsProvider.overrideWith(
          (ref) async => const [Avd(name: 'Pixel_8'), Avd(name: _longAvd)],
        ),
        deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
        hostCanRunSimulatorsProvider.overrideWithValue(true),
        iosSimulatorsProvider.overrideWith(
          (ref) async =>
              simulators ?? [_sim('ipad', 'iPad'), _sim('iphone', 'iPhone')],
        ),
        simulatorBackendProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: DevicePane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _keyStartsWith(String prefix) => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith(prefix);
});

/// Where an action's *ink* ends: its glyph or its word, not the padding a
/// button wraps around them.
double _inkRight(WidgetTester tester, Finder action) {
  for (final type in [Icon, Text]) {
    final ink = find.descendant(of: action, matching: find.byType(type));
    if (ink.evaluate().isNotEmpty) return tester.getRect(ink.first).right;
  }
  return tester.getRect(action).right;
}

Finder get _emulatorsHeader => find.textContaining(
  RegExp(r'^(android )?emulators$', caseSensitive: false),
);
Finder get _simulatorsHeader =>
    find.textContaining(RegExp(r'^ios simulators$', caseSensitive: false));
Finder get _slimLabels =>
    find.textContaining(RegExp(r'^Slim( \w+)? on start$'));

void main() {
  testWidgets('headers, names and option labels share one left edge', (
    tester,
  ) async {
    await _pump(tester);

    final lefts = {
      // The toolbar's picker starts the same column the list is drawn in.
      'device picker': tester.getRect(find.text('No device selected')).left,
      'emulators header': tester.getRect(_emulatorsHeader).left,
      'simulators header': tester.getRect(_simulatorsHeader).left,
      'emulator name': tester.getRect(find.text('Pixel_8')).left,
      'simulator name': tester.getRect(find.textContaining('iPad').first).left,
      'window option': tester.getRect(find.text('Start without a window')).left,
      for (final (i, label) in _slimLabels.evaluate().indexed)
        'slim option $i': tester.getRect(find.byWidget(label.widget)).left,
    };
    expect(lefts.length, greaterThanOrEqualTo(8), reason: '$lefts');
    expect(lefts.values.toSet(), hasLength(1), reason: '$lefts');
  });

  testWidgets('every trailing action ends on one right edge', (tester) async {
    await _pump(tester);

    final rights = <String, double>{
      for (final (i, e) in _keyStartsWith('start-avd-').evaluate().indexed)
        'start emulator $i': _inkRight(tester, find.byWidget(e.widget)),
      for (final (i, e) in _keyStartsWith('start-simulator').evaluate().indexed)
        'start simulator $i': _inkRight(tester, find.byWidget(e.widget)),
      'emulator slimming': _inkRight(
        tester,
        find.byKey(const Key('android-slimming-open')),
      ),
      'simulator slimming': _inkRight(
        tester,
        find.byKey(const Key('simulator-slimming-open')),
      ),
      for (final (i, e) in find.byType(Switch).evaluate().indexed)
        'switch $i': tester.getRect(find.byWidget(e.widget)).right,
      for (final (i, e) in find.byType(Checkbox).evaluate().indexed)
        'checkbox $i': tester.getRect(find.byWidget(e.widget)).right,
    };
    expect(rights.length, greaterThanOrEqualTo(7), reason: '$rights');
    expect(
      rights.values.map((right) => right.roundToDouble()).toSet(),
      hasLength(1),
      reason: '$rights',
    );
    // And that edge keeps the pane's margin: nothing runs to the pane's side.
    expect(rights.values.first, lessThanOrEqualTo(320 - Insets.sm));
  });

  testWidgets('an emulator and a simulator are the same row', (tester) async {
    await _pump(tester);

    for (final name in ['Pixel_8', 'iPad']) {
      expect(
        find.ancestor(of: find.text(name), matching: find.byType(DeviceRow)),
        findsOneWidget,
        reason: '$name is a DeviceRow',
      );
    }
    // Not a picker: every simulator that can start is a row with its own Start.
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(_keyStartsWith('start-simulator'), findsNWidgets(2));
    expect(_keyStartsWith('start-avd-'), findsNWidgets(2));
    final starts = [
      ..._keyStartsWith('start-avd-').evaluate(),
      ..._keyStartsWith('start-simulator').evaluate(),
    ];
    expect({for (final e in starts) e.widget.runtimeType}, {DeviceRowAction});
  });

  testWidgets('the options are one kind of control', (tester) async {
    await _pump(tester);

    // Three options: the window, and slimming once per platform.
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(DeviceSwitchRow), findsNWidgets(3));
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('a long name takes the free width before it is cut short', (
    tester,
  ) async {
    await _pump(tester);

    final name = tester.getRect(find.text(_longAvd));
    final start = tester.getRect(find.byKey(const Key('start-avd-$_longAvd')));
    expect(
      start.left - name.right,
      lessThanOrEqualTo(Insets.md),
      reason: 'nothing but a gap sits between a cut name and its action',
    );
    expect(name.width, greaterThan(320 * 0.7));
  });

  testWidgets('the empty message is short, and the list starts under it', (
    tester,
  ) async {
    await _pump(tester);

    final placeholder = tester.widget<PanePlaceholder>(
      find.byType(PanePlaceholder),
    );
    expect(placeholder.inline, isTrue, reason: 'a line, not a hero block');
    expect(placeholder.message.length, lessThanOrEqualTo(100));
    expect(placeholder.message, contains('No device connected'));
    final gap =
        tester.getRect(_emulatorsHeader).top -
        tester.getRect(find.byType(PanePlaceholder)).bottom;
    expect(gap, lessThanOrEqualTo(Insets.lg));
    // Top-aligned: a list that is centred moves every time a row comes or goes.
    expect(
      tester.getRect(find.byType(PanePlaceholder)).top,
      lessThan(Chrome.tabStrip * 2),
    );
  });

  testWidgets('a long simulator list is folded, not a dropdown', (
    tester,
  ) async {
    await _pump(
      tester,
      simulators: [for (var i = 0; i < 40; i++) _sim('u$i', 'iPhone $i')],
    );

    expect(_keyStartsWith('start-simulator').evaluate().length, lessThan(10));
    final more = find.byKey(const Key('simulators-show-all'));
    expect(more, findsOneWidget);
    expect(find.text('Show all (40)'), findsOneWidget);
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(_keyStartsWith('start-simulator'), findsNWidgets(40));
  });

  testWidgets('slimming is a switch on both platforms, and it is the setting', (
    tester,
  ) async {
    await _pump(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DevicePane)),
    );

    expect(
      container.read(deviceSlimmingPreferencesProvider).androidSlimming,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('android-slim-on-start')));
    await tester.pumpAndSettle();
    expect(
      container.read(deviceSlimmingPreferencesProvider).androidSlimming,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('slim-on-start')));
    await tester.pumpAndSettle();
    expect(
      container.read(deviceSlimmingPreferencesProvider).simulatorSlimming,
      isTrue,
    );
  });

  testWidgets(
    'the keyboard reaches every action, and a switch row is one stop',
    (tester) async {
      await _pump(tester);

      final reached = <String>{};
      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused == null) continue;
        focused.visitAncestorElements((element) {
          final key = element.widget.key;
          if (key is ValueKey<String>) reached.add(key.value);
          return true;
        });
      }
      expect(
        reached,
        containsAll([
          'android-slimming-open',
          'start-avd-Pixel_8',
          'simulator-slimming-open',
          'start-simulator-ipad',
          'headless-emulator-toggle',
          'android-slim-on-start',
          'slim-on-start',
        ]),
      );

      // The row is the control: focused, Space flips it.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DevicePane)),
      );
      expect(container.read(headlessDeviceProvider), isTrue);
      Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byKey(const Key('headless-emulator-toggle')),
                matching: find.byType(Row),
              )
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(container.read(headlessDeviceProvider), isFalse);
    },
  );

  testWidgets('a pointer over a row washes it with the hover token', (
    tester,
  ) async {
    await _pump(tester);

    Color? fillOf(String name) =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .ancestor(
                            of: find.text(name),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(fillOf('Pixel_8'), isNull);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Pixel_8')));
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.text('Pixel_8'))).colorScheme;
    expect(fillOf('Pixel_8'), StateLayers.hover(scheme));
    expect(fillOf('iPad'), isNull);
  });

  for (final width in [240.0, 320.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('holds at ${width.toInt()}px, ${scale}x text', (
        tester,
      ) async {
        await _pump(tester, width: width, textScale: scale);

        expect(tester.takeException(), isNull);
        for (final action in [
          ..._keyStartsWith('start-avd-').evaluate(),
          ..._keyStartsWith('start-simulator').evaluate(),
          ...find.byType(Switch).evaluate(),
        ]) {
          final finder = find.byWidget(action.widget);
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          expect(finder.hitTestable(), findsOneWidget);
        }
        // The name still has most of the row.
        expect(
          tester.getSize(find.text(_longAvd)).width,
          greaterThanOrEqualTo(width * 0.6),
        );
      });
    }
  }
}
