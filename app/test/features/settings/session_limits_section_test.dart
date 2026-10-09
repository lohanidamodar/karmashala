import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/session_limits_section.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// Settings › General › Session limits: a field per scope, blank for none,
/// the pause and the usage hold, written to `settings.v1` for the server.
void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakeDataServer(clock: () => testTime);
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:archlinux', distro: 'archlinux'));
    server.installationRows.upsert(agentInstallation());
    server.projectRows.insert(project(name: 'Karmashala'));
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: SessionLimitsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(TextField),
  );

  LaunchLimits limits(ProviderContainer c) =>
      c.read(settingsControllerProvider).launchLimits;

  testWidgets('a row per scope; a number sets a limit and blank clears it', (
    tester,
  ) async {
    final c = await pump(tester);
    expect(find.text(kLaunchSlotRule), findsOneWidget);
    expect(find.text('All sessions'), findsOneWidget);
    expect(find.text('Per machine'), findsOneWidget);
    expect(find.text('Per agent account'), findsOneWidget);
    expect(find.text('Per project'), findsOneWidget);
    expect(find.text('Karmashala'), findsOneWidget);
    expect(find.text('No limit'), findsWidgets);

    await tester.enterText(field('limits-global'), '4');
    await tester.enterText(field('limits-machine-wsl:archlinux'), '2');
    await tester.enterText(field('limits-project-p1'), '1');
    await tester.pump();
    expect(limits(c).global, 4);
    expect(limits(c).machines, {'wsl:archlinux': 2});
    expect(limits(c).projects, {'p1': 1});

    await tester.enterText(field('limits-global'), '');
    await tester.pump();
    expect(limits(c).global, isNull);
    // Zero is no limit; pausing is the switch.
    await tester.enterText(field('limits-machine-wsl:archlinux'), '0');
    await tester.pump();
    expect(limits(c).machines, isEmpty);
  });

  testWidgets('the pause and the usage hold', (tester) async {
    final c = await pump(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('limits-pause')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pump();
    expect(limits(c).pauseBackground, isTrue);

    await tester.enterText(field('limits-hold'), '250');
    await tester.pump();
    expect(limits(c).holdBackgroundAbovePercent, 100);
  });

  for (final (name, size, scale) in [
    ('360 px', const Size(360, 800), 1.0),
    ('360 px at text scale 1.6', const Size(360, 800), 1.6),
    ('desktop at text scale 1.6', const Size(1440, 900), 1.6),
  ]) {
    testWidgets('it lays out without overflow: $name', (tester) async {
      await pump(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(field('limits-global'), findsOneWidget);
    });
  }
}
