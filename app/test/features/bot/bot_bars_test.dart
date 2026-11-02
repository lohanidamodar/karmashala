import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_top_bar.dart';
import 'package:karmashala/src/app/shell/shell_title_bar.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';

import '../../support/desktop_client.dart';
import 'bot_support.dart';

Future<void> pumpBar(
  WidgetTester tester,
  ProviderContainer container,
  PreferredSizeWidget bar,
  double scale,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(appBar: bar, body: const SizedBox.shrink()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late BotRig rig;

  setUp(() => rig = BotRig());

  for (final scale in const [1.0, 1.6]) {
    testWidgets('the phone top bar holds the button at 360 and $scale', (
      tester,
    ) async {
      sizeWindow(tester, const Size(360, 740));
      final container = await rig.container();
      await pumpBar(tester, container, const PhoneTopBar(), scale);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('bot-button')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('bot-button'))).height,
        greaterThanOrEqualTo(48),
      );
    });

    for (final width in const [600.0, 1600.0]) {
      testWidgets('the title bar holds the button at $width and $scale', (
        tester,
      ) async {
        sizeWindow(tester, Size(width, 800));
        final container = await rig.container(
          overrides: [
            clientCapabilitiesProvider.overrideWithValue(desktopClient()),
          ],
        );
        await pumpBar(tester, container, const ShellTitleBar(), scale);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('bot-button')), findsOneWidget);
      });
    }
  }

  test('the shortcut is taken by nothing else', () {
    final chords = defaultShellChords.where(
      (c) => c.activator.trigger.keyLabel == 'M' && c.activator.shift,
    );
    expect(chords.map((c) => c.command), ['bot.toggle']);
  });
}
