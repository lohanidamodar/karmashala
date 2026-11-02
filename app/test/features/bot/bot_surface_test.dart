import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/bot/application/bot_providers.dart';
import 'package:karmashala/src/features/bot/presentation/bot_button.dart';
import 'package:karmashala/src/features/bot/presentation/bot_surface.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/desktop_client.dart';
import 'bot_support.dart';

Future<void> pumpHost(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final wide = MediaQuery.sizeOf(context).width >= 600;
              final open = ref.watch(botPanelProvider);
              final button = const Center(child: BotButton());
              return wide
                  ? Stack(
                      children: [
                        button,
                        if (open)
                          const Positioned(
                            top: 0,
                            bottom: 0,
                            right: 0,
                            width: Chrome.botPanelWidth,
                            child: BotFloatingPanel(),
                          ),
                      ],
                    )
                  : BotPhoneSheetHost(child: button);
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late BotRig rig;

  setUp(() => rig = BotRig());

  group('the button', () {
    testWidgets('an older server has no button', (tester) async {
      final container = await rig.container(features: const {'sessions.send'});
      await pumpHost(tester, container);
      expect(find.byKey(const ValueKey('bot-button')), findsNothing);
    });

    testWidgets('away from the server it is disabled, with its reason', (
      tester,
    ) async {
      final container = await rig.container(
        overrides: [
          clientCapabilitiesProvider.overrideWithValue(desktopClient()),
        ],
      );
      await pumpHost(tester, container);
      rig.server.stop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-button')));
      await tester.pump();
      expect(container.read(botPanelProvider), isFalse);
      final tip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const ValueKey('bot-button')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tip.message, contains('Not connected to the server'));
      rig.server.start();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    });

    testWidgets('the dot says what waits', (tester) async {
      botRow(rig);
      final container = await rig.container();
      await pumpHost(tester, container);
      expect(find.byKey(const ValueKey('bot-dot:waiting')), findsNothing);
      rig.bot.ask(approvalOf('a'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-dot:waiting')), findsOneWidget);
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        find.bySemanticsLabel('Bot, waiting for your answer'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('desktop', () {
    testWidgets('a floating panel, and the app under it stays usable', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1400, 900));
      final container = await rig.container();
      await pumpHost(tester, container);

      await tester.tap(find.byKey(const ValueKey('bot-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-panel')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('bot-panel'))).width,
        Chrome.botPanelWidth,
      );
      // The button is still there to press: nothing modal came up.
      await tester.tap(find.byKey(const ValueKey('bot-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-panel')), findsNothing);
    });

    testWidgets('it uses the floating shadow', (tester) async {
      sizeWindow(tester, const Size(1400, 900));
      final container = await rig.container();
      container.read(botPanelProvider.notifier).open();
      await pumpHost(tester, container);
      final box = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('bot-panel')),
      );
      expect((box.decoration as BoxDecoration).boxShadow, Shadows.floating);
    });
  });

  group('phone', () {
    testWidgets('a sheet of about 88% of the height', (tester) async {
      sizeWindow(tester, const Size(360, 740));
      final container = await rig.container();
      await pumpHost(tester, container);

      await tester.tap(find.byKey(const ValueKey('bot-button')));
      await tester.pumpAndSettle();
      final height = tester
          .getSize(find.byKey(const ValueKey('bot-sheet')))
          .height;
      expect(height, closeTo(740 * Chrome.botSheetShare, 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing it lowers the flag, and the flag lowers it', (
      tester,
    ) async {
      sizeWindow(tester, const Size(360, 740));
      final container = await rig.container();
      await pumpHost(tester, container);

      container.read(botPanelProvider.notifier).open();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-sheet')), findsNothing);
      expect(container.read(botPanelProvider), isFalse);

      container.read(botPanelProvider.notifier).open();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-sheet')), findsOneWidget);
      await tester.tapAt(const Offset(180, 10));
      await tester.pumpAndSettle();
      expect(container.read(botPanelProvider), isFalse);
    });

    testWidgets('widening keeps it open, as the panel', (tester) async {
      sizeWindow(tester, const Size(360, 740));
      final container = await rig.container();
      await pumpHost(tester, container);
      container.read(botPanelProvider.notifier).open();
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(1400, 900);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('bot-panel')), findsOneWidget);
      expect(container.read(botPanelProvider), isTrue);

      tester.view.physicalSize = const Size(360, 740);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('bot-panel')), findsNothing);
    });
  });
}
