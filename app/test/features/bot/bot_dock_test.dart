import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/bot/application/bot_providers.dart';
import 'package:karmashala/src/features/bot/presentation/bot_surface.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/desktop_client.dart';
import 'bot_support.dart';

/// **A pinned bot docks beside the workbench** where the window has room,
/// and its chord moves the keys in and out of it rather than closing it.
void main() {
  late BotRig rig;

  setUp(() => rig = BotRig());

  final dock = find.byKey(const ValueKey('shell-bot-dock'));
  final floating = find.byKey(const ValueKey('shell-bot'));

  bool typingInPanel() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.findAncestorWidgetOfExactType<EditableText>() != null &&
        context?.findAncestorWidgetOfExactType<BotDesktopPanel>() != null;
  }

  Future<ProviderContainer> pumpShell(
    WidgetTester tester,
    Size size, {
    bool pinned = true,
  }) async {
    sizeWindow(tester, size);
    final container = await rig.container(
      overrides: [
        clientCapabilitiesProvider.overrideWithValue(desktopClient()),
      ],
    );
    if (pinned) {
      container.read(settingsControllerProvider.notifier).setBotPinned(true);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  test('the column needs the workbench floor beside it', () {
    expect(
      ShellLayout.botFits(
        available: ShellLayout.workbenchFloor + Chrome.botPanelWidth,
        explorerColumn: false,
      ),
      isTrue,
    );
    expect(
      ShellLayout.botFits(
        available: ShellLayout.workbenchFloor + Chrome.botPanelWidth,
        explorerColumn: true,
      ),
      isFalse,
    );
  });

  testWidgets('pinned, it is up from the start, and leaves the keys alone', (
    tester,
  ) async {
    final container = await pumpShell(tester, const Size(1440, 900));
    expect(dock, findsOneWidget);
    expect(floating, findsNothing);
    expect(container.read(botDockedProvider), isTrue);
    expect(typingInPanel(), isFalse);
    await unmount(tester);
  });

  testWidgets('where the window has no room it floats', (tester) async {
    final container = await pumpShell(tester, const Size(860, 700));
    expect(dock, findsNothing);
    expect(floating, findsOneWidget);
    expect(container.read(botDockedProvider), isFalse);
    await unmount(tester);
  });

  testWidgets('the pin docks it, and takes it back out', (tester) async {
    final container = await pumpShell(
      tester,
      const Size(1440, 900),
      pinned: false,
    );
    container.read(botPanelProvider.notifier).open();
    await tester.pumpAndSettle();
    expect(floating, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bot-pin')));
    await tester.pumpAndSettle();
    expect(dock, findsOneWidget);
    expect(container.read(settingsControllerProvider).botPinned, isTrue);
    await tester.tap(find.byKey(const ValueKey('bot-pin')));
    await tester.pumpAndSettle();
    expect(floating, findsOneWidget);
    expect(dock, findsNothing);
    await unmount(tester);
  });

  testWidgets('the chord moves the keys in, and back, and leaves it up', (
    tester,
  ) async {
    final container = await pumpShell(tester, const Size(1440, 900));
    final before = FocusManager.instance.primaryFocus;
    final panel = container.read(botPanelProvider.notifier);

    panel.chord();
    await tester.pumpAndSettle();
    expect(typingInPanel(), isTrue);
    expect(container.read(botPanelProvider), isTrue);

    panel.chord();
    await tester.pumpAndSettle();
    expect(typingInPanel(), isFalse);
    expect(FocusManager.instance.primaryFocus, before);
    expect(dock, findsOneWidget);
    await unmount(tester);
  });

  testWidgets('closed with its button, the chord brings it back typing', (
    tester,
  ) async {
    final container = await pumpShell(tester, const Size(1440, 900));
    final panel = container.read(botPanelProvider.notifier);
    panel.close();
    await tester.pumpAndSettle();
    expect(dock, findsNothing);

    panel.chord();
    await tester.pumpAndSettle();
    expect(dock, findsOneWidget);
    expect(typingInPanel(), isTrue);
    await unmount(tester);
  });

  testWidgets('floating, the chord still opens and closes it', (tester) async {
    final container = await pumpShell(
      tester,
      const Size(1440, 900),
      pinned: false,
    );
    final panel = container.read(botPanelProvider.notifier);
    panel.chord();
    await tester.pumpAndSettle();
    expect(floating, findsOneWidget);
    expect(typingInPanel(), isTrue);
    panel.chord();
    await tester.pumpAndSettle();
    expect(floating, findsNothing);
    await unmount(tester);
  });
}
