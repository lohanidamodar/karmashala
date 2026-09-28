import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_state.dart';
import 'package:karmashala/src/app/shell/shell_area.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

/// The inbox in the shell: one count, three places that show it, and a list
/// that jumps to the thing it names.
///
/// The point of these tests is **agreement**. Before this loop the tray badge,
/// the tray menu and the (non-existent) in-app count were three different
/// derivations of the same idea, and nothing checked that they matched.
void main() {
  // These cases press `Ctrl+…` by name, so they pin the platform whose command
  // modifier that is. The chord table follows the host — on macOS every one of
  // them is `⌘` instead — and which modifier carries a command is pinned in
  // `shell_shortcuts_platform_test.dart`. What is under test here is what the
  // chord *does*, which is the same on every platform.
  setUp(() => commandKeyIsMeta = false);

  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;

  const key = AgentSessionKey('claudeCode', 'cli-1');
  const watched = WatchedSession(
    key: key,
    label: 'Fix login',
    openId: 's1',
    imported: false,
  );

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(session(id: 's1', title: 'Fix login'));
  });

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // Session cards ask git about their checkout; the shell must never
        // spawn one from a test.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        // Selecting a session starts the real status poll, whose timer
        // outlives the widget tree and trips flutter_test's invariant.
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
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
  }

  void queue({bool approval = false}) =>
      FakeDataServer.of(container.read(dataClientProvider)).attention.apply(
        InboxUpdate(
          watched: {key},
          waiting: approval
              ? const [
                  SessionAttention(
                    session: watched,
                    kind: AttentionKind.needsInput,
                  ),
                ]
              : const [],
          news: approval
              ? const []
              : const [(session: watched, reason: NotificationReason.finished)],
        ),
      );

  Future<void> pressInboxShortcut(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  // The activity strip's Inbox, named with its count.
  Finder stripInbox() => find.bySemanticsLabel('Inbox, 1 need you');

  testWidgets('the strip says nothing while nothing is waiting', (
    tester,
  ) async {
    await pump(tester);
    expect(find.bySemanticsLabel(RegExp('Inbox, .* need you')), findsNothing);
    expect(find.textContaining('need you'), findsNothing);
  });

  testWidgets("the strip badge is the inbox's count", (tester) async {
    await pump(tester);
    queue();
    await tester.pumpAndSettle();

    expect(stripInbox(), findsOneWidget);
    expect(container.read(attentionCountProvider), 1);
  });

  testWidgets("the strip's Inbox opens the inbox", (tester) async {
    await pump(tester);
    queue();
    await tester.pumpAndSettle();

    await tester.tap(stripInbox());
    await tester.pumpAndSettle();

    expect(container.read(shellAreaProvider), ShellArea.inbox);
    expect(find.text('Fix login'), findsWidgets);
  });

  testWidgets('Ctrl+Shift+A opens the inbox, and closes it again', (
    tester,
  ) async {
    await pump(tester);

    await pressInboxShortcut(tester);
    expect(container.read(shellAreaProvider), ShellArea.inbox);
    expect(container.read(shellControllerProvider).explorerPaneVisible, isTrue);

    await pressInboxShortcut(tester);
    expect(
      container.read(shellControllerProvider).explorerPaneVisible,
      isFalse,
    );
  });

  testWidgets('an empty inbox says so rather than showing a blank panel', (
    tester,
  ) async {
    await pump(tester);
    await pressInboxShortcut(tester);
    expect(find.text('Nothing needs you.'), findsOneWidget);
  });

  testWidgets('opening an item from the list clears the count everywhere', (
    tester,
  ) async {
    await pump(tester);
    queue();
    await tester.pumpAndSettle();
    await pressInboxShortcut(tester);

    expect(find.text('Finished  ·  just now'), findsOneWidget);
    await tester.tap(find.text('Finished  ·  just now'));
    await tester.pumpAndSettle();

    expect(container.read(selectedSessionIdProvider), 's1');
    expect(container.read(attentionCountProvider), 0);
    expect(find.text('1 needs you'), findsNothing);
    expect(find.text('Nothing needs you.'), findsOneWidget);
  });

  testWidgets('an approval stays in the list after it has been read', (
    tester,
  ) async {
    await pump(tester);
    queue(approval: true);
    await tester.pumpAndSettle();
    await pressInboxShortcut(tester);

    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();

    expect(container.read(attentionCountProvider), 0);
    expect(find.textContaining('Needs approval'), findsOneWidget);
    expect(find.text('Nothing needs you.'), findsNothing);
  });
}
