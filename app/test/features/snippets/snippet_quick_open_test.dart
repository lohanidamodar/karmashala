import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open_item.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/snippets/application/snippet_providers.dart';
import 'package:karmashala/src/features/snippets/domain/command_snippet.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import 'package:agent_cli/process.dart';
import '../../support/test_machine.dart';
import '../../support/conversation_index_database.dart';

/// Snippets as a **group of quick open**, rather than a second palette.
///
/// The two things worth pinning here are the ones a reader cannot see from the
/// source: that the `$` sigil reaches the group at all, and that picking a row
/// types into the pane that was in front *before the dialog took the keyboard*.
/// The second is the whole feature — see [resolveSnippetTarget] — and it is only
/// observable by reading what the pane would have handed its PTY.
void main() {
  late FakeDataServer server;
  late TestMachine db;

  setUp(() {
    // Quick Open catches up the conversation index, still in the store (1f).
    db = TestMachine();
    server = FakeDataServer()
      ..projectRows.insert(project(name: 'Karmashala'))
      ..repositoryRows.insert(repository(name: 'app'));
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
  });

  /// Opens a pane on [profile], saves [snippets], then opens the palette.
  ///
  /// Returns the container and the list the focused pane would have sent to its
  /// process, so a picked snippet can be read at the only level that tells
  /// "typed" from "run".
  Future<({ProviderContainer container, List<String> written, String paneId})>
  open(
    WidgetTester tester, {
    TerminalProfile profile = TerminalProfile.powerShell,
    List<({String label, String command, String? shell, bool submit})>
        snippets =
        const [],
  }) async {
    final container = ProviderContainer(
      overrides: [
        conversationIndexDatabase(),
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(profile);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    final written = <String>[];
    controller.instanceFor(paneId)!.terminal.onOutput = written.add;

    for (final entry in snippets) {
      container
          .read(commandSnippetsProvider.notifier)
          .add(
            label: entry.label,
            command: entry.command,
            shellId: entry.shell,
            submit: entry.submit,
          );
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (container: container, written: written, paneId: paneId);
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  const testsSnippet = (
    label: 'Run the tests',
    command: 'flutter test --exclude-tags=live-ssh',
    shell: null,
    submit: false,
  );

  testWidgets(r'$ lists the library under its own header', (tester) async {
    await open(tester, snippets: const [testsSnippet]);

    await type(tester, r'$');

    expect(find.text('COMMAND SNIPPETS'), findsOneWidget);
    expect(find.text('Run the tests'), findsOneWidget);
    expect(find.text('flutter test --exclude-tags=live-ssh'), findsOneWidget);
    // The sigil is a filter, so nothing else in the workspace is listed.
    expect(find.text('PROJECTS & REPOSITORIES'), findsNothing);
  });

  testWidgets('a snippet is found by name without the sigil', (tester) async {
    await open(tester, snippets: const [testsSnippet]);

    await type(tester, 'run the tests');

    expect(find.text('COMMAND SNIPPETS'), findsOneWidget);
    expect(find.text('Run the tests'), findsOneWidget);
  });

  testWidgets('picking one types it into the pane, and does not run it', (
    tester,
  ) async {
    final opened = await open(tester, snippets: const [testsSnippet]);

    await type(tester, r'$run the tests');
    await tester.tap(find.text('Run the tests'));
    await tester.pumpAndSettle();

    expect(opened.written, [
      'flutter test --exclude-tags=live-ssh',
    ], reason: 'no carriage return: the user presses Enter');
    // And the palette got out of the way, so the command is visible.
    expect(find.byType(QuickOpen), findsNothing);
  });

  testWidgets('one the user marked "runs" says so before it is picked', (
    tester,
  ) async {
    await open(
      tester,
      snippets: const [
        (label: 'Clean', command: 'flutter clean', shell: null, submit: true),
      ],
    );

    await type(tester, r'$');

    // The badge is the warning, and it is on the row rather than in a
    // confirmation afterwards.
    expect(find.text('runs'), findsOneWidget);
  });

  group('the shell filter', () {
    const wslOnly = (
      label: 'Tail the log',
      command: 'tail -f /var/log/syslog',
      shell: 'wsl',
      submit: false,
    );
    const powerShellOnly = (
      label: 'List processes',
      command: 'Get-Process',
      shell: 'powerShell',
      submit: false,
    );

    testWidgets('a PowerShell pane is offered neither WSL nor nothing', (
      tester,
    ) async {
      await open(
        tester,
        snippets: const [testsSnippet, wslOnly, powerShellOnly],
      );

      await type(tester, r'$');

      expect(find.text('List processes'), findsOneWidget);
      expect(find.text('Run the tests'), findsOneWidget, reason: 'untagged');
      expect(
        find.text('Tail the log'),
        findsNothing,
        reason:
            'a WSL one-liner in a PowerShell pane is not a smaller version of '
            'the same thing',
      );
    });

    /// **Filtering is right; being silent about it is not.**
    ///
    /// The rule above is deliberate — a WSL one-liner is not a smaller version
    /// of a PowerShell one — but on the owner's machine it produced a palette
    /// with nothing in it and no reason given, because his one snippet was
    /// tagged `wsl` and every pane he works in is an agent pane. "My snippet
    /// is not there" is what that looks like from outside.
    ///
    /// So the omission gets a line. It says which pane you are in when that is
    /// known, and says the shell is unknown when it is not — two different
    /// facts, never collapsed into one sentence.
    testWidgets('a hidden snippet is accounted for, not just absent', (
      tester,
    ) async {
      await open(tester, snippets: const [testsSnippet, wslOnly]);

      await type(tester, r'$');

      expect(find.text('Tail the log'), findsNothing, reason: 'still hidden');
      expect(
        find.textContaining('for another shell'),
        findsOneWidget,
        reason: 'the palette says one was held back, and why',
      );
    });

    testWidgets('and nothing is said when nothing was hidden', (tester) async {
      await open(tester, snippets: const [testsSnippet]);

      await type(tester, r'$');

      expect(find.text('Run the tests'), findsOneWidget);
      expect(find.textContaining('for another shell'), findsNothing);
    });

    testWidgets('and a WSL pane on the same machine sees the other two', (
      tester,
    ) async {
      await open(
        tester,
        profile: const TerminalProfile(
          id: 'wsl:Ubuntu',
          label: 'Ubuntu (WSL)',
          shell: TerminalShell.wsl,
          wslDistribution: 'Ubuntu',
        ),
        snippets: const [testsSnippet, wslOnly, powerShellOnly],
      );

      await type(tester, r'$');

      expect(find.text('Tail the log'), findsOneWidget);
      expect(find.text('Run the tests'), findsOneWidget);
      expect(find.text('List processes'), findsNothing);
    });
  });

  testWidgets('an empty library still offers somewhere to go', (tester) async {
    await open(tester);

    await type(tester, r'$');

    // The reason the two management rows are in the snippets group rather than
    // under Commands: the toolbar button opens `$`, and a dead end there would
    // be the first thing a new user saw.
    expect(find.text('Nothing matches.'), findsNothing);
    expect(find.text('New command snippet…'), findsOneWidget);
    expect(find.text('Manage command snippets…'), findsOneWidget);
  });

  test(r'the $ sigil belongs to the snippets group and nothing else', () {
    expect(QuickOpenGroup.snippets.sigil, r'$');
    expect(QuickOpenQuery.parse(r'$git').only, QuickOpenGroup.snippets);
    expect(QuickOpenQuery.parse(r'$git').text, 'git');
    for (final group in QuickOpenGroup.values) {
      if (group == QuickOpenGroup.snippets) continue;
      expect(group.sigil, isNot(r'$'));
    }
  });

  test('the chord that opens it is declared in the registry', () {
    // Not spelled out by any tooltip: the toolbar reads it back from here, so
    // the button and the keyboard cannot drift apart.
    commandKeyIsMeta = false;
    addTearDown(() => commandKeyIsMeta = false);
    expect(
      shellChordLabel<OpenQuickOpenIntent>(where: (i) => i.query == r'$'),
      'Ctrl+Shift+S',
    );
  });

  testWidgets('the palette survives the window matrix with snippets in it', (
    tester,
  ) async {
    // Seeded at the server, once: [expectSurvivesWindowMatrix] calls `build`
    // afresh per cell, and a controller writing under a fixed clock would issue
    // the same id three times.
    server.snippetRows.insert(
      CommandSnippet(
        // Long on purpose. The row is a title over a subtitle in a fixed-height
        // box, so the cell that finds an overflow is 720x560 at 1.3x text with
        // something in it that cannot be shown in one line.
        id: 'sn-long',
        label: 'Run the tests on this machine only, excluding the live ones',
        command:
            'flutter test --exclude-tags=live-ssh,live-wsl --concurrency=4',
        createdAt: testTime,
        updatedAt: testTime,
      ),
    );
    final client = await server.connect();
    await expectSurvivesWindowMatrix(
      tester,
      because: 'quick open with the snippets group listed',
      build: () {
        final container = ProviderContainer(
          overrides: [
            conversationIndexDatabase(),
            ...fakeTerminalOverrides(machine: db),
            dataClientProvider.overrideWithValue(client),
            clockProvider.overrideWithValue(FixedClock(testTime)),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(terminalSessionsControllerProvider.notifier)
            .openTab(TerminalProfile.powerShell);
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => QuickOpen.show(context, initialQuery: r'$'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
      },
      warmUp: (tester) async {
        await tester.tap(find.text('open'));
        await tester.pump();
      },
    );
  });
}
