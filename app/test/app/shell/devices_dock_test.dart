import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/devices_dock.dart';
import 'package:karmashala_ui/theme.dart';

/// The Devices dock (UI overhaul spec §4), drawn from values.
void main() {
  Future<List<DockDevice?>> pump(
    WidgetTester tester,
    List<DockDevice> devices,
  ) async {
    final opened = <DockDevice?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(
              width: 264,
              child: DevicesDock(devices: devices, onOpen: opened.add),
            ),
          ),
        ),
      ),
    );
    return opened;
  }

  DockDevice device(String id, {bool ready = true}) =>
      DockDevice(id: id, name: 'Phone $id', emulator: false, ready: ready);

  testWidgets('with nothing connected it says so on one line', (tester) async {
    await pump(tester, const []);
    expect(find.text('DEVICES'), findsOneWidget);
    expect(find.text('none'), findsOneWidget);
  });

  testWidgets('each device is a line; its dot says whether it answers', (
    tester,
  ) async {
    await pump(tester, [device('a'), device('b', ready: false)]);
    expect(find.text('Phone a'), findsOneWidget);
    expect(find.text('Phone b'), findsOneWidget);
    Finder dot(String label) => find.byWidgetPredicate(
      (w) => w is Icon && w.semanticLabel == label,
    );
    expect(dot('connected'), findsOneWidget);
    expect(dot('offline'), findsOneWidget);
  });

  testWidgets('past three it folds the rest into a count', (tester) async {
    await pump(tester, [for (final id in 'abcde'.split('')) device(id)]);
    expect(find.text('Phone c'), findsOneWidget);
    expect(find.text('Phone d'), findsNothing);
    expect(find.text('2 more'), findsOneWidget);
  });

  testWidgets('opening a device names it; the header names none', (
    tester,
  ) async {
    final a = device('a');
    final opened = await pump(tester, [a]);
    await tester.tap(find.text('Phone a'));
    await tester.tap(find.text('DEVICES'));
    expect(opened, [a, null]);
  });
}
