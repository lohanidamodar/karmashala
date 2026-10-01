import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/terminal/fake_instance.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/test_machine.dart';
import 'package:agent_cli/process.dart';
import '../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The UI text-size setting, applied where everything inherits it.
///
/// The user's complaint was precise: the menus did not follow text sizing.
/// So the proof is precise too — a menu-bar label, measured through the real
/// app root, must grow when the setting does.
void main() {
  group('composeTextScaler', () {
    test('identity in, identity out', () {
      expect(
        composeTextScaler(TextScaler.noScaling, 1.0),
        TextScaler.noScaling,
      );
    });

    test('multiplies the OS scale instead of replacing it', () {
      final scaler = composeTextScaler(const TextScaler.linear(1.3), 1.25);
      expect(scaler.scale(14.0), closeTo(14.0 * 1.3 * 1.25, 0.001));
    });

    test('applies the app scale alone when the OS asks for nothing', () {
      expect(
        composeTextScaler(TextScaler.noScaling, 1.5).scale(10.0),
        closeTo(15.0, 0.001),
      );
    });
  });

  group('through the app root', () {
    late TestMachine db;
    late FakeDataServer server;
    late Override data;

    setUp(() async {
      db = TestMachine();
      server = FakeDataServer()..runsOn(db);
      server.environmentRows.upsert(
        localHostEnvironment(FixedClock(testTime).nowUtc()),
      );
      data = await server.override();
    });

    testWidgets('a title-bar label follows the setting', (tester) async {
      final container = fakeTerminalContainer(machine: db, data: data);
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const KarmashalaApp(),
        ),
      );
      await tester.pumpAndSettle();

      // The menu titles went behind one glyph (b2063bc4d); the quick panel
      // field's words are the title bar's text now.
      Finder label() => find
          .descendant(
            of: find.byType(QuickOpenButton),
            matching: find.byType(Text),
          )
          .first;
      final before = tester.getSize(label());
      expect(
        tester.getSize(find.byType(ShellTitleBar)).height,
        Chrome.titleBar,
        reason: 'at 100% the chrome keeps its design height',
      );

      container.read(settingsControllerProvider.notifier).setUiTextScale(1.5);
      await tester.pumpAndSettle();

      final after = tester.getSize(label());
      expect(
        after.height,
        greaterThan(before.height * 1.3),
        reason:
            'the title bar\'s label must scale with the UI text size setting',
      );
      expect(
        tester.getSize(find.byType(ShellTitleBar)).height,
        greaterThan(Chrome.titleBar),
        reason: 'the title bar grows so the scaled label is not clipped',
      );
    });
  });
}
