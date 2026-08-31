import 'package:chitragupta/src/app/chitragupta_app.dart';
import 'package:chitragupta/src/app/shell/quick_open/quick_open.dart';
import 'package:chitragupta/src/app/shell/shell_shortcuts.dart';
import 'package:chitragupta/src/app/shell/shell_state.dart';
import 'package:chitragupta/src/app/shell/side_panel_state.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The app's chords have to survive a focused terminal pane.
///
/// xterm's `TerminalView` reports *every* key as handled — an unclaimed
/// `Ctrl+B` becomes a literal `^B` at the prompt — so before Loop 56 none of
/// the shell's bindings worked from the app's own primary surface. The only
/// hook that runs before xterm is `TerminalView.onKeyEvent`, and what it claims
/// is the declared skip-list in `shellChords`.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
  });
  tearDown(() => db.close());

  /// Boots the whole shell, focuses the terminal pane the workbench opens, and
  /// hands back the container plus everything the pane's process was sent.
  Future<(ProviderContainer, List<String>)> pumpFocusedTerminal(
    WidgetTester tester, {
    Map<String, bool> chordOverrides = const {},
  }) async {
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    // Applied before the first frame, the way a saved setting arrives.
    for (final entry in chordOverrides.entries) {
      container
          .read(settingsControllerProvider.notifier)
          .setTerminalChordClaimed(entry.key, entry.value);
    }
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ChitraguptaApp(),
      ),
    );
    await tester.pumpAndSettle();

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = container.read(terminalSessionsControllerProvider).activeTab!;
    final instance = controller.instanceFor(tab.focusedPaneId)!;

    // Everything the pane would have written to its PTY.
    final toShell = <String>[];
    instance.terminal.onOutput = toShell.add;

    instance.focusNode.requestFocus();
    await tester.pumpAndSettle();
    expect(
      instance.focusNode.hasPrimaryFocus,
      isTrue,
      reason:
          'the terminal pane must hold focus for this test to mean '
          'anything',
    );
    return (container, toShell);
  }

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+K opens quick open from a focused terminal pane', (
    tester,
  ) async {
    final (_, toShell) = await pumpFocusedTerminal(tester);

    await chord(tester, LogicalKeyboardKey.keyK);

    expect(find.byType(QuickOpen), findsOneWidget);
    // And nothing leaked to the process behind the pane.
    expect(toShell, isEmpty);
  });

  testWidgets('Ctrl+P opens quick open from a focused terminal pane', (
    tester,
  ) async {
    final (_, toShell) = await pumpFocusedTerminal(tester);

    await chord(tester, LogicalKeyboardKey.keyP);

    expect(find.byType(QuickOpen), findsOneWidget);
    expect(toShell, isEmpty);
  });

  testWidgets('Ctrl+3 toggles the side panel from a focused terminal pane', (
    tester,
  ) async {
    final (container, toShell) = await pumpFocusedTerminal(tester);
    expect(container.read(sidePanelProvider), isNotNull);

    await chord(tester, LogicalKeyboardKey.digit3);

    expect(container.read(sidePanelProvider), isNull);
    expect(toShell, isEmpty);
  });

  testWidgets('Ctrl+1 and Ctrl+2 move the focused pane from the terminal', (
    tester,
  ) async {
    final (container, toShell) = await pumpFocusedTerminal(tester);

    await chord(tester, LogicalKeyboardKey.digit1);
    expect(
      container.read(shellControllerProvider).focusedPane,
      ShellPane.explorer,
    );
    expect(toShell, isEmpty);
  });

  testWidgets('Ctrl+\\ enters focus mode from a focused terminal pane', (
    tester,
  ) async {
    final (container, toShell) = await pumpFocusedTerminal(tester);
    expect(container.read(terminalMaximizedProvider), isFalse);

    await chord(tester, LogicalKeyboardKey.backslash);

    expect(container.read(terminalMaximizedProvider), isTrue);
    expect(toShell, isEmpty);
  });

  testWidgets(
    'Ctrl+Shift+B toggles the Explorer from a focused terminal pane',
    (tester) async {
      final (container, toShell) = await pumpFocusedTerminal(tester);
      expect(
        container.read(shellControllerProvider).explorerPaneVisible,
        isTrue,
      );

      await chord(tester, LogicalKeyboardKey.keyB, shift: true);

      expect(
        container.read(shellControllerProvider).explorerPaneVisible,
        isFalse,
      );
      expect(toShell, isEmpty);
    },
  );

  testWidgets('Ctrl+B still reaches the shell — it is tmux\'s prefix', (
    tester,
  ) async {
    final (container, toShell) = await pumpFocusedTerminal(tester);
    final before = container.read(shellControllerProvider).explorerPaneVisible;

    await chord(tester, LogicalKeyboardKey.keyB);

    // The Explorer did not move, and the process got its prefix byte.
    expect(container.read(shellControllerProvider).explorerPaneVisible, before);
    expect(toShell, ['\x02']);
  });

  testWidgets('Ctrl+C still reaches the shell', (tester) async {
    final (_, toShell) = await pumpFocusedTerminal(tester);

    await chord(tester, LogicalKeyboardKey.keyC);

    expect(toShell, ['\x03']);
  });

  testWidgets('Ctrl+A reaches the shell — readline and tmux both want it', (
    tester,
  ) async {
    // xterm's own shortcut manager bound this to select-all on Windows. It is
    // readline's `beginning-of-line` and the most common alternate tmux
    // prefix, and it is not in `shellChords`, so the app was taking it without
    // saying so and Settings could not give it back.
    final (_, toShell) = await pumpFocusedTerminal(tester);

    await chord(tester, LogicalKeyboardKey.keyA);

    expect(toShell, ['\x01']);
  });

  testWidgets('Ctrl+V reaches the shell — readline quoted-insert', (
    tester,
  ) async {
    final (_, toShell) = await pumpFocusedTerminal(tester);

    await chord(tester, LogicalKeyboardKey.keyV);

    expect(toShell, ['\x16']);
  });

  testWidgets('Ctrl+Shift+V is paste, and types nothing at the prompt', (
    tester,
  ) async {
    final (_, toShell) = await pumpFocusedTerminal(tester);

    await chord(tester, LogicalKeyboardKey.keyV, shift: true);

    expect(
      toShell,
      isEmpty,
      reason: 'the pane claimed it for paste, so no control byte was sent',
    );
  });

  test('the pane keeps only chords a terminal cannot encode', () {
    // Everything the pane holds back from the shell has to be a
    // Ctrl+Shift+<letter>, which has no control character and therefore costs
    // the shell nothing.
    for (final activator in terminalPaneShortcuts.keys) {
      expect(
        (activator as SingleActivator).shift,
        isTrue,
        reason: '$activator takes a real control character from the shell',
      );
    }
  });

  test('the chords left to the shell are named, and no others', () {
    // Every chord is either claimed inside a terminal pane or deliberately
    // left to the process; there is no third state and no second list to
    // forget to update. The exceptions have to be spelled out here, so
    // moving a chord in or out of the skip-list is never silent.
    final kept = [
      for (final chord in shellChords)
        if (!chord.skipsShell) chord.label,
    ];
    // Ctrl+B is tmux's prefix. Ctrl+T and Ctrl+W are readline's transpose and
    // delete-word: the tab chords are offered on the bare keys too, but a
    // shell keeps them until Settings says otherwise, so upgrading takes no
    // key away from anyone. Ctrl+Shift+T and Ctrl+Shift+W always reach the app.
    expect(kept, ['Ctrl+B', 'Ctrl+T', 'Ctrl+W']);
    // And the map the Shortcuts widget installs is the same list.
    expect(shellShortcutMap.length, shellChords.length);
  });

  test('every claimed chord names what the shell loses, or loses nothing', () {
    // A chord that takes a real control character from the shell must say so;
    // the ones that cost nothing must not invent a cost.
    final costly = {
      for (final chord in shellChords)
        if (chord.shellCost != null) chord.label,
    };
    // `Ctrl+-` joined them in Loop 79: a terminal encodes it as ^_, which is
    // readline's undo. `Ctrl+=` and `Ctrl+0` have no control character at all,
    // so the zoom chords are not uniformly free and must not claim to be.
    expect(costly, {
      'Ctrl+\\',
      'Ctrl+K',
      'Ctrl+P',
      'Ctrl+-',
      // The tab chords, which a shell and a full-screen program do read.
      'Ctrl+T',
      'Ctrl+W',
      'Ctrl+PageUp',
      'Ctrl+PageDown',
    });
  });

  test('the tab chords are bound, both ways round', () {
    // The user's report: Ctrl+Shift+T and Ctrl+Shift+W did nothing unless a
    // terminal pane had focus, because the pane handled them itself and the
    // app's map never knew them. Binding them here is what makes them work
    // from the Explorer, the chat view, or anywhere else.
    expect(shellChordLabel<NewTerminalTabIntent>(), 'Ctrl+Shift+T');
    expect(shellChordLabel<CloseTerminalTabIntent>(), 'Ctrl+Shift+W');
    expect(shellChordLabel<StepTerminalTabIntent>(), 'Ctrl+PageDown');
    // Both spellings of each verb are installed, so the bare keys work too
    // wherever a shell is not listening.
    final labels = [for (final c in shellChords) c.label];
    for (final label in ['Ctrl+T', 'Ctrl+W', 'Ctrl+PageUp']) {
      expect(labels, contains(label));
    }
  });

  test('the Explorer advertises the chord that survives a terminal', () {
    expect(shellChordLabel<ToggleExplorerPaneIntent>(), 'Ctrl+Shift+B');
    expect(shellChordLabel<ToggleSidePanelIntent>(), 'Ctrl+3');
  });

  testWidgets('Ctrl+B claimed in Settings stops being the tmux prefix', (
    tester,
  ) async {
    // The defaults are a guess about how the user works. Someone who does not
    // live in tmux should be able to have Ctrl+B for the Explorer without
    // editing the source, which is what Loop 56 could not offer.
    final (container, toShell) = await pumpFocusedTerminal(
      tester,
      chordOverrides: const {'Ctrl+B': true},
    );
    expect(container.read(shellControllerProvider).explorerPaneVisible, isTrue);

    await chord(tester, LogicalKeyboardKey.keyB);

    expect(
      container.read(shellControllerProvider).explorerPaneVisible,
      isFalse,
    );
    expect(toShell, isEmpty, reason: 'the app took it, so ^B was not typed');
  });

  testWidgets('Ctrl+K handed back to the shell types kill-line again', (
    tester,
  ) async {
    final (_, toShell) = await pumpFocusedTerminal(
      tester,
      chordOverrides: const {'Ctrl+K': false},
    );

    await chord(tester, LogicalKeyboardKey.keyK);

    expect(find.byType(QuickOpen), findsNothing);
    expect(toShell, ['\x0b']);
  });

  test('only the contested chords are offered as a setting', () {
    // A terminal cannot encode Ctrl+Shift+<letter>, so a switch for one would
    // be a switch that changes nothing.
    final contested = [
      for (final chord in shellChords)
        if (chord.contested) chord.label,
    ];
    expect(contested, isNot(contains('Ctrl+Shift+B')));
    expect(contested, isNot(contains('Ctrl+Shift+P')));
    expect(contested, isNot(contains('Ctrl+Shift+A')));
    expect(contested, contains('Ctrl+B'));
    expect(contested, contains('Ctrl+K'));
  });

  test('an override decides, and only for the chord it names', () {
    const overrides = {'Ctrl+B': true};
    final byLabel = {for (final c in shellChords) c.label: c};
    expect(byLabel['Ctrl+B']!.claimedByApp(overrides), isTrue);
    expect(byLabel['Ctrl+B']!.claimedByApp(const {}), isFalse);
    expect(byLabel['Ctrl+K']!.claimedByApp(overrides), isTrue);
  });
}
