import 'dart:math' as math;

import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/onboarding/application/quick_start.dart';
import 'package:karmashala/src/features/onboarding/presentation/quick_start_card.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

/// The sidebar's list and the quick start below it each keep their own
/// room: at a 1480-wide window the inbox's last row once sat cut flush
/// against the card, as if under it.
void main() {
  setUp(() => commandKeyIsMeta = false);

  for (final size in const [Size(1480, 953), Size(720, 560)]) {
    testWidgets(
      'at ${size.width.toInt()}×${size.height.toInt()} the inbox keeps its room above the quick start',
      (tester) async {
        final db = TestMachine();
        final server = FakeDataServer()..runsOn(db);
        final data = await server.override();
        server.environmentRows.upsert(
          localHostEnvironment(FixedClock(testTime).nowUtc()),
        );
        server.projectRows.insert(project());
        server.repositoryRows.insert(repository());
        server.installationRows.insert(agentInstallation());
        final watched = <WatchedSession>[];
        for (var i = 0; i < 12; i++) {
          db.server.sessionRows.insert(
            session(id: 's$i', title: 'New session $i'),
          );
          watched.add(
            WatchedSession(
              key: AgentSessionKey('claudeCode', 'cli-$i'),
              label: 'New session $i',
              openId: 's$i',
              imported: false,
            ),
          );
        }
        final container = ProviderContainer(
          overrides: [
            data,
            ...fakeTerminalOverrides(machine: db),
            clockProvider.overrideWithValue(FixedClock(testTime)),
            commandRunnerFactoryProvider.overrideWithValue(
              FakeCommandRunnerFactory(),
            ),
            availableSystemTerminalsProvider.overrideWith(
              (ref) async => const <SystemTerminal>[],
            ),
            autoImportRunnerProvider.overrideWithValue(
              (_) async => const ImportSummary(),
            ),
            agentSessionStatusProvider.overrideWith(
              (ref, id) => const Stream<AgentStatusReport>.empty(),
            ),
          ],
        );
        addTearDown(container.dispose);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const KarmashalaApp(),
          ),
        );
        await tester.pumpAndSettle();
        FakeDataServer.of(container.read(dataClientProvider)).attention.apply(
          InboxUpdate(
            watched: {for (final w in watched) w.key},
            news: [
              for (final w in watched)
                (session: w, reason: NotificationReason.finished),
            ],
          ),
        );
        await tester.pumpAndSettle();
        container.read(quickStartProvider.notifier).reopen();
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        final card = find.descendant(
          of: find.byType(QuickStartCard),
          matching: find.byType(DecoratedBox),
        );
        final list = find.descendant(
          of: find.byType(AttentionInboxView),
          matching: find.byType(Scrollable),
        );
        final viewport = tester.getRect(list.first);
        final cardTop = tester.getRect(card.first).top;
        expect(
          cardTop - viewport.bottom,
          greaterThanOrEqualTo(Insets.sm),
          reason: 'the card stands off the list, not flush against its edge',
        );

        Iterable<Rect> rows() => [
          for (final e
              in find
                  .descendant(
                    of: find.byType(AttentionInboxView),
                    matching: find.textContaining('New session'),
                  )
                  .evaluate())
            tester.getRect(find.byWidget(e.widget)),
        ];
        final whole = rows().where(
          (r) => r.top >= viewport.top && r.bottom <= viewport.bottom,
        );
        expect(whole.length, greaterThanOrEqualTo(3), reason: 'the list room');

        // The last row scrolls into view above the card.
        await tester.drag(list.first, const Offset(0, -2000));
        await tester.pumpAndSettle();
        final lowest = rows().map((r) => r.bottom).reduce(math.max);
        expect(lowest, lessThanOrEqualTo(viewport.bottom));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
