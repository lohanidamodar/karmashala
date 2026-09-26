import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/features/snippets/application/snippet_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../../support/fake_data_server.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import '../../support/test_machine.dart';
import '../../support/conversation_index_database.dart';

/// What the snippets button costs the terminal's typing path, in counts.
///
/// The house rule this file obeys is the one `keystroke_cost_test.dart` states:
/// **count work, never time it**, because the suite runs at `--concurrency=4`
/// and a wall-clock assertion over a few milliseconds is a coin toss. The unit
/// here is builds of [TerminalToolbar], which sits in the tab strip directly
/// above a pane somebody types into all day.
///
/// The regression this exists to prevent is a specific and tempting one: hiding
/// the snippets button when the library is empty, or badging it with a count.
/// Either would make the strip a consumer of `commandSnippetsProvider`, and a
/// widget that watches a provider is a widget that rebuilds when Riverpod
/// republishes it — which is why the button is unconditional and asks nothing.
/// The empty case is answered inside the picker instead.
void main() {
  // One case below finds the button by its tooltip, which carries the chord
  // spelled for the host: `Ctrl+Shift+S` on Windows and Linux, `⇧⌘S` on macOS.
  // Naming one spelling means pinning the platform it belongs to, the same way
  // `attention_inbox_shell_test.dart` does and for the same reason — what is
  // under test here is what the button *does*, which is the same everywhere.
  // Without this the file passed on Windows, where it was written, and failed
  // on every Mac with `Found 0 widgets`.
  final hostCommandKeyIsMeta = commandKeyIsMeta;
  setUp(() => commandKeyIsMeta = false);
  // Restored because this is a process-wide global and the file does not own
  // it: a later suite in the same isolate must see the host's own answer.
  tearDownAll(() => commandKeyIsMeta = hostCommandKeyIsMeta);

  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    server = FakeDataServer();
    // The picker catches up the conversation index, still in the store (1f).
    final db = TestMachine();
    container = ProviderContainer(
      overrides: [
        conversationIndexDatabase(),
        ...fakeTerminalOverrides(machine: db, data: await server.override()),
      ],
    );
  });
  tearDown(() => container.dispose());

  TerminalSessionsController controller() =>
      container.read(terminalSessionsControllerProvider.notifier);

  /// The strip as the workbench builds it: a rail that absorbs whatever is
  /// left, then the toolbar, in a row exactly [Chrome.tabStrip] tall.
  Widget strip() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: Chrome.tabStrip,
            child: Row(
              children: const [
                Expanded(child: SizedBox()),
                TerminalToolbar(),
                SizedBox(width: Insets.xs),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// Mounts the strip over one live pane and returns it.
  Future<FakeTerminalInstance> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    controller().openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    await tester.pumpWidget(strip());
    await tester.pump();
    return controller().instanceFor(paneId)! as FakeTerminalInstance;
  }

  testWidgets('a keystroke and its echo rebuild the toolbar not at all', (
    tester,
  ) async {
    final pane = await mount(tester);
    // The guard against a false green: without this the zero below could just
    // mean the toolbar was never built in the first place.
    expect(TerminalToolbar.debugBuildCount, greaterThan(0));
    final typed = <String>[];
    pane.terminal.onOutput = typed.add;

    TerminalToolbar.debugBuildCount = 0;
    server.requests.clear();
    for (final letter in 'flutter test'.split('')) {
      pane.terminal.textInput(letter);
      pane.receive(letter);
      await tester.pump();
    }

    expect(
      typed,
      isNotEmpty,
      reason:
          'nothing below means anything unless the keystrokes actually reached '
          'the terminal',
    );
    expect(
      TerminalToolbar.debugBuildCount,
      0,
      reason:
          'the snippets button must not subscribe the strip to anything that '
          'moves while somebody types',
    );
    expect(
      server.requests,
      isEmpty,
      reason: 'typing a character says nothing about any stored row',
    );
  });

  testWidgets('saving a snippet rebuilds the toolbar not at all', (
    tester,
  ) async {
    // The specific temptation. A count badge or a hide-when-empty rule would
    // make this non-zero, and would put a provider republish on the strip's
    // path for a button whose whole job is to open a picker.
    await mount(tester);
    TerminalToolbar.debugBuildCount = 0;

    container
        .read(commandSnippetsProvider.notifier)
        .add(label: 'Run the tests', command: 'flutter test');
    await tester.pump();

    expect(container.read(commandSnippetsProvider), hasLength(1));
    expect(TerminalToolbar.debugBuildCount, 0);
  });

  testWidgets('and a pane changing directory rebuilds it not at all', (
    tester,
  ) async {
    // OSC 7 republishes `TerminalSessionsState`, and the strip selects two
    // narrow things out of it. A `cd` moves neither.
    final pane = await mount(tester);
    TerminalToolbar.debugBuildCount = 0;

    pane.terminal.write('\x1b]7;file://host/c:/work/karmashala\x07');
    await tester.pump();

    expect(TerminalToolbar.debugBuildCount, 0);
  });

  testWidgets('the button opens the picker on the snippets group', (
    tester,
  ) async {
    await mount(tester);

    await tester.tap(find.byTooltip('Command snippets (Ctrl+Shift+S)'));
    await tester.pumpAndSettle();

    expect(find.byType(QuickOpen), findsOneWidget);
    expect(find.text('COMMAND SNIPPETS'), findsOneWidget);
    // Seeded straight into the filtered group rather than into everything.
    expect(find.text('New command snippet…'), findsOneWidget);
  });

  testWidgets('the toolbar survives the window matrix with the button on it', (
    tester,
  ) async {
    // The strip is tight and has overflowed before, and this adds an eighth
    // control to it. The worst case is measured, not the ordinary one: a
    // background session badge and the shell-integration commands button are
    // both present below, so every button the toolbar can draw is drawn.
    await expectSurvivesWindowMatrix(
      tester,
      because: 'the terminal toolbar with the snippets button added',
      build: () {
        final scope = ProviderContainer(
          overrides: [...fakeTerminalOverrides(shellIntegration: true)],
        );
        addTearDown(scope.dispose);
        final terminals = scope.read(
          terminalSessionsControllerProvider.notifier,
        );

        // A detached session, so the background badge is drawn.
        final parked = terminals.openTab(TerminalProfile.powerShell);
        giveShellHistory(
          terminals.instanceFor(
            scope
                .read(terminalSessionsControllerProvider)
                .activeTab!
                .focusedPaneId,
          )!,
        );
        terminals.closeTab(parked, detach: true);

        // And a focused pane with one OSC 133 command in it, so the commands
        // button is drawn too.
        terminals.openTab(TerminalProfile.powerShell);
        final paneId = scope
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .focusedPaneId;
        terminals.instanceFor(paneId)!.terminal
          ..write('\x1b]133;A\x07PS C:\\ws> \x1b]133;B\x07flutter test\r\n')
          ..write('\x1b]133;C\x07ok\r\n')
          ..write('\x1b]133;D;0\x07');

        return UncontrolledProviderScope(
          container: scope,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  height: Chrome.tabStrip,
                  child: Row(
                    children: const [
                      Expanded(child: SizedBox()),
                      TerminalToolbar(),
                      SizedBox(width: Insets.xs),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  });
}
