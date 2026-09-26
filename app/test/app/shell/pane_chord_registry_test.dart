import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_search_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The comment on `ShellChord` promises that the `Shortcuts` map and the
/// terminal skip-list are one list read two ways. For three loops it was not
/// true: `Ctrl+Shift+D`, `Ctrl+Shift+E` and `Ctrl+Shift+F` were dispatched by an
/// `if` chain inside `TerminalActions.onPaneKey` and appeared in no
/// `ShellChord`, so `shellChordLabel` could not see them and three tooltips
/// spelled them out by hand.
///
/// A comment cannot hold that line, so this file does. The two lists *can* be
/// compared programmatically — [appChordForTerminal] is the registry's own
/// matcher, and `onPaneKey` is the only thing that answers for a pane's keys —
/// so the sweep below presses every plausible chord at a real pane handler and
/// fails if the two ever disagree.
void main() {
  // The chord table follows the host; these cases press `Ctrl+…` by name.
  setUp(() => commandKeyIsMeta = false);

  late AppDatabase db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
  });
  tearDown(() => db.close());

  /// Every key worth pressing with a modifier down.
  const keys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyB,
    LogicalKeyboardKey.keyC,
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.keyE,
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyG,
    LogicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyI,
    LogicalKeyboardKey.keyJ,
    LogicalKeyboardKey.keyK,
    LogicalKeyboardKey.keyL,
    LogicalKeyboardKey.keyM,
    LogicalKeyboardKey.keyN,
    LogicalKeyboardKey.keyO,
    LogicalKeyboardKey.keyP,
    LogicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyR,
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyT,
    LogicalKeyboardKey.keyU,
    LogicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyX,
    LogicalKeyboardKey.keyY,
    LogicalKeyboardKey.keyZ,
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.insert,
    LogicalKeyboardKey.backquote,
    LogicalKeyboardKey.backslash,
    LogicalKeyboardKey.slash,
    LogicalKeyboardKey.minus,
    LogicalKeyboardKey.equal,
    LogicalKeyboardKey.bracketLeft,
    LogicalKeyboardKey.bracketRight,
    LogicalKeyboardKey.semicolon,
    LogicalKeyboardKey.quote,
    LogicalKeyboardKey.comma,
    LogicalKeyboardKey.period,
  ];

  /// A pane key handler, and a focus node with a context to give it.
  ///
  /// Deliberately not the whole app: the sweep uses key-*up* events, which
  /// [handleAppChordFromTerminal] matches and swallows without invoking
  /// anything (see its doc — the up of a claimed combo must not reach the
  /// shell), so nothing has to survive being pressed 250 times.
  Future<(FocusOnKeyEventCallback, FocusNode)> paneKeyHandler(
    WidgetTester tester, {
    Map<String, bool> chordOverrides = const {},
  }) async {
    final container = fakeTerminalContainer(database: db, data: data);
    addTearDown(container.dispose);
    for (final entry in chordOverrides.entries) {
      container
          .read(settingsControllerProvider.notifier)
          .setTerminalChordClaimed(entry.key, entry.value);
    }
    final node = FocusNode();
    addTearDown(node.dispose);
    late FocusOnKeyEventCallback onPaneKey;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(
            builder: (context, ref, _) {
              onPaneKey = TerminalActions(ref).onPaneKey;
              return Focus(focusNode: node, child: const SizedBox.shrink());
            },
          ),
        ),
      ),
    );
    return (onPaneKey, node);
  }

  /// The up half of a combo. Matched by the registry exactly like the down
  /// half, and dispatches nothing.
  KeyEvent release(LogicalKeyboardKey key) => KeyUpEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    timeStamp: Duration.zero,
  );

  Future<void> hold(
    WidgetTester tester,
    List<LogicalKeyboardKey> modifiers,
    Future<void> Function() body,
  ) async {
    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await body();
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
  }

  testWidgets('the pane claims a chord only if shellChords declares it', (
    tester,
  ) async {
    final (onPaneKey, node) = await paneKeyHandler(tester);

    const combos = <List<LogicalKeyboardKey>>[
      [LogicalKeyboardKey.controlLeft],
      [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft],
      [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft],
      [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.shiftLeft,
      ],
    ];
    for (final modifiers in combos) {
      await hold(tester, modifiers, () async {
        for (final key in keys) {
          final event = release(key);
          final claimed = onPaneKey(node, event) == KeyEventResult.handled;
          final declared = appChordForTerminal(event) != null;
          expect(
            claimed,
            declared,
            reason: claimed
                ? '${key.keyLabel} with '
                      '${modifiers.map((m) => m.keyLabel).join('+')} is handled '
                      'by the pane but declared in no ShellChord — add it to '
                      'shellChords rather than to onPaneKey'
                : '${key.keyLabel} with '
                      '${modifiers.map((m) => m.keyLabel).join('+')} is '
                      'declared but the pane lets it through to the shell',
          );
        }
      });
    }
  });

  testWidgets('an unmodified key is always the process\'s', (tester) async {
    // The typing path. Nothing in the registry is bound without a modifier,
    // and a pane that claimed one would eat the user's keystrokes.
    final (onPaneKey, node) = await paneKeyHandler(tester);

    for (final key in keys) {
      expect(
        onPaneKey(node, release(key)),
        KeyEventResult.ignored,
        reason: '${key.keyLabel} must reach the shell',
      );
    }
  });

  testWidgets('the pane honours an override on a chord it used to shadow', (
    tester,
  ) async {
    // `Ctrl+PageUp` is declared, contested, and was *also* stepped by
    // `onPaneKey`'s own chain — which ran first, so the answer the user gave
    // Settings did nothing while a pane had focus.
    final (onPaneKey, node) = await paneKeyHandler(
      tester,
      chordOverrides: const {'Ctrl+PageUp': false},
    );

    await hold(tester, const [LogicalKeyboardKey.controlLeft], () async {
      expect(
        onPaneKey(node, release(LogicalKeyboardKey.pageUp)),
        KeyEventResult.ignored,
        reason: 'handed back, so the page-up belongs to the process',
      );
      expect(
        onPaneKey(node, release(LogicalKeyboardKey.pageDown)),
        KeyEventResult.handled,
        reason: 'and only the chord the override names changed',
      );
    });
  });

  test('the pane verbs are declared, and their labels are readable', () {
    // What the toolbar tooltips and the pane menu now read instead of spelling
    // a keystroke out for themselves.
    expect(shellChordLabel<FindInScrollbackIntent>(), 'Ctrl+Shift+F');
    expect(
      shellChordLabel<SplitTerminalPaneIntent>(
        where: (i) => i.axis == SplitAxis.horizontal,
      ),
      'Ctrl+Shift+D',
    );
    expect(
      shellChordLabel<SplitTerminalPaneIntent>(
        where: (i) => i.axis == SplitAxis.vertical,
      ),
      'Ctrl+Shift+E',
    );
  });

  test('pane-local chords are declared but never bound app-wide', () {
    // Binding `Ctrl+Shift+↑/↓` app-wide would take Flutter's own
    // extend-selection-by-paragraph out of every text field in the app.
    final paneLocal = [
      for (final chord in shellChords)
        if (chord.paneLocal) chord.label,
    ];
    expect(paneLocal, [
      'Ctrl+Shift+Up',
      'Ctrl+Shift+Down',
      'Ctrl+Shift+PageUp',
      'Ctrl+Shift+PageDown',
      'Ctrl+Alt+Left',
      'Ctrl+Alt+Right',
      'Ctrl+Alt+Up',
      'Ctrl+Alt+Down',
    ]);
    for (final chord in shellChords) {
      if (!chord.paneLocal) continue;
      expect(
        shellShortcutMap.containsKey(chord.activator),
        isFalse,
        reason: '${chord.label} must not be bound outside a pane',
      );
      expect(
        chord.contested,
        isFalse,
        reason: '${chord.label} has no app-wide binding to trade away',
      );
    }
  });

  group('the folded chords still do what they did', () {
    /// The whole shell, with the workbench's terminal pane focused.
    Future<(ProviderContainer, List<String>)> pumpFocusedTerminal(
      WidgetTester tester,
    ) async {
      final container = fakeTerminalContainer(database: db, data: data);
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

      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tab = container.read(terminalSessionsControllerProvider).activeTab!;
      final instance = controller.instanceFor(tab.focusedPaneId)!;
      final toShell = <String>[];
      instance.terminal.onOutput = toShell.add;
      instance.focusNode.requestFocus();
      await tester.pumpAndSettle();
      expect(instance.focusNode.hasPrimaryFocus, isTrue);
      return (container, toShell);
    }

    Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('Ctrl+Shift+D splits the workspace right', (tester) async {
      final (container, toShell) = await pumpFocusedTerminal(tester);

      await chord(tester, LogicalKeyboardKey.keyD);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.workspace!.groups, hasLength(2));
      // The new group is the empty room a split clears, so there is nothing to
      // be typing into until something lands in it.
      expect(state.activeTabId, isNull);
      expect(toShell, isEmpty);
    });

    testWidgets('the chord splits the empty group it just made, to a floor', (
      tester,
    ) async {
      final (container, toShell) = await pumpFocusedTerminal(tester);

      await chord(tester, LogicalKeyboardKey.keyD);
      await chord(tester, LogicalKeyboardKey.keyE);

      var state = container.read(terminalSessionsControllerProvider);
      expect(state.workspace!.groups, hasLength(3));
      expect(state.activeTabId, isNull);

      // What a held key amounts to: size stops it, four halvings in.
      for (var i = 0; i < 8; i++) {
        await chord(tester, LogicalKeyboardKey.keyD);
      }
      state = container.read(terminalSessionsControllerProvider);
      expect(state.workspace!.groups, hasLength(6));
      expect(toShell, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Ctrl+Shift+E splits the workspace down', (tester) async {
      final (container, toShell) = await pumpFocusedTerminal(tester);

      await chord(tester, LogicalKeyboardKey.keyE);

      expect(
        container.read(terminalSessionsControllerProvider).workspace!.groups,
        hasLength(2),
      );
      expect(toShell, isEmpty);
    });

    testWidgets('Ctrl+Shift+F opens the scrollback search', (tester) async {
      final (container, toShell) = await pumpFocusedTerminal(tester);
      expect(container.read(terminalSearchControllerProvider).visible, isFalse);

      await chord(tester, LogicalKeyboardKey.keyF);

      expect(container.read(terminalSearchControllerProvider).visible, isTrue);
      expect(toShell, isEmpty);
    });
  });
}
