import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/bot/presentation/bot_settings_section.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'bot_support.dart';

Future<void> pumpRow(
  WidgetTester tester,
  ProviderContainer container, {
  double scale = 1,
}) async {
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
        home: const Scaffold(
          body: SingleChildScrollView(child: BotSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late BotRig rig;

  setUp(() => rig = BotRig());

  testWidgets('an older server has no row', (tester) async {
    final container = await rig.container(features: const {'sessions.send'});
    await pumpRow(tester, container);
    expect(find.byKey(const ValueKey('bot-setting')), findsNothing);
  });

  testWidgets(
    'Default agent is the default, then each agent with a chat form',
    (tester) async {
      final container = await rig.container();
      await pumpRow(tester, container);
      expect(find.text('Default agent'), findsOneWidget);

      await tester.tap(find.text('Default agent'));
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsWidgets);
      expect(find.text('Codex'), findsWidgets);

      await tester.tap(find.text('Codex').last);
      await tester.pumpAndSettle();
      expect(
        rig.bot.asked.whereType<BotAgentSet>().single.agentId,
        'codex-acp',
      );
    },
  );

  testWidgets('a choice from another client shows here', (tester) async {
    final container = await rig.container();
    await pumpRow(tester, container);
    rig.bot.tell([
      const BotAgentChanged(agentId: 'codex-acp', agentSetting: 'codex-acp'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Codex'), findsOneWidget);
  });

  testWidgets('a refused choice stays where it was and says why', (
    tester,
  ) async {
    rig.bot.agentRefusal = DataRefused(
      DataRefusalCode.conflict,
      'A turn is running.',
    );
    final container = await rig.container();
    await pumpRow(tester, container);
    await tester.tap(find.text('Default agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex').last);
    await tester.pumpAndSettle();
    expect(find.text('A turn is running.'), findsOneWidget);
    expect(find.text('Default agent'), findsOneWidget);
  });

  testWidgets('no agent: says so, with nothing to pick', (tester) async {
    rig.bot.agents = const [];
    final container = await rig.container();
    await pumpRow(tester, container);
    expect(find.byType(DropdownButtonFormField<String?>), findsNothing);
    expect(find.textContaining('No agent'), findsOneWidget);
  });

  for (final (name, size, scale) in panelMatrix) {
    testWidgets('no overflow at $name', (tester) async {
      sizeWindow(tester, size);
      final container = await rig.container();
      await pumpRow(tester, container, scale: scale);
      expect(tester.takeException(), isNull);
    });
  }
}
