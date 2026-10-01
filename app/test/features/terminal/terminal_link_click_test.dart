import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/features/terminal/application/terminal_link_actions.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';
import '../../support/test_machine.dart';

/// What a Ctrl+click in a terminal pane actually does.
///
/// "any link — file link, relative file link, http link — clickable with proper
/// opening on the terminal", and "detection only should run on ctrl click or
/// ctrl and hover should underline like other terminals does".
///
/// So the two properties this file is really about: **nothing is detected until
/// Ctrl is held**, and what a click reaches is the injected
/// [TerminalLinkActions] seam — never a real browser, editor, Explorer or
/// filesystem.
void main() {
  const cwd = r'C:\src\app';
  const resolvedMain = r'C:\src\app\lib\main.dart';

  late TestMachine db;
  late _RecordingLinkActions actions;
  late ProviderContainer container;

  setUp(() {
    db = TestMachine();
    actions = _RecordingLinkActions();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          machine: db,
          // A pane that opened somewhere, so a relative path has something to
          // be relative to.
          instanceFactory:
              ({
                required String id,
                required TerminalProfile profile,
                String? workingDirectory,
                String? restoredScrollback,
                bool shellIntegration = false,
                AgentPaneLaunch? agentLaunch,
                Terminal? adoptTerminal,
              }) => FakeTerminalInstance(
                id: id,
                title: profile.label,
                profileId: profile.id,
                workingDirectory: workingDirectory ?? cwd,
                restored: restoredScrollback,
                adoptTerminal: adoptTerminal,
              ),
        ),
        terminalLinkActionsProvider.overrideWithValue(actions),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  /// Pumps the workbench, writes [output] into its one pane, and returns that
  /// pane's instance.
  Future<TerminalInstance> pumpWithOutput(
    WidgetTester tester,
    String output,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    openFirstTerminal(container);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = container.read(terminalSessionsControllerProvider).activeTab!;
    final instance = controller.instanceFor(tab.focusedPaneId)!;
    instance.terminal.write(output);
    await tester.pumpAndSettle();
    return instance;
  }

  /// The screen position of the centre of cell ([column], [row]).
  ///
  /// Asked of the render object rather than computed from a font size: the
  /// cell metrics are the terminal's, and a test that guessed them would be
  /// testing its own arithmetic.
  Offset centreOfCell(WidgetTester tester, int column, int row) {
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    final cell = render.cellSize;
    return render.localToGlobal(
      render.getOffset(CellOffset(column, row)) +
          Offset(cell.width / 2, cell.height / 2),
    );
  }

  Future<TestGesture> hover(WidgetTester tester, Offset position) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(() => mouse.removePointer());
    await mouse.moveTo(position);
    await tester.pumpAndSettle();
    return mouse;
  }

  Future<void> pressCtrl(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> releaseCtrl(WidgetTester tester) async {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// A Ctrl+click at [target], with the double-tap timer xterm arms let expire.
  Future<void> ctrlClick(
    WidgetTester tester,
    TestGesture mouse,
    Offset target,
  ) async {
    await mouse.down(target);
    await tester.pump();
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  MouseCursor cursor(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).mouseCursor;

  group('Ctrl is the switch', () {
    testWidgets('with Ctrl up, hovering resolves nothing at all', (
      tester,
    ) async {
      final instance = await pumpWithOutput(
        tester,
        'edit lib/main.dart and see https://example.com/a',
      );
      actions.exists[resolvedMain] = TerminalPathKind.file;

      // Sweep across the path, the URL and the prose between them.
      final mouse = await hover(tester, centreOfCell(tester, 5, 0));
      for (final column in [7, 12, 20, 30, 35]) {
        await mouse.moveTo(centreOfCell(tester, column, 0));
        await tester.pumpAndSettle();
      }

      expect(
        actions.probed,
        isEmpty,
        reason: 'the seam is never reached with the modifier up',
      );
      expect(instance.controller.underlines, isEmpty);
      expect(find.textContaining('click to'), findsNothing);
      expect(cursor(tester), SystemMouseCursors.text);
    });

    testWidgets('holding Ctrl underlines the path under the pointer', (
      tester,
    ) async {
      final instance = await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      await hover(tester, centreOfCell(tester, 8, 0));

      await pressCtrl(tester);

      final highlight = instance.controller.underlines.single;
      expect(
        instance.controller.highlights,
        isEmpty,
        reason: 'a rule, not a wash',
      );
      // Exactly `lib/main.dart`, which starts at column 5 and is 13 long.
      expect(highlight.range!.begin, const CellOffset(5, 0));
      expect(highlight.range!.end, const CellOffset(18, 0));
      expect(cursor(tester), SystemMouseCursors.click);
      expect(find.textContaining(resolvedMain), findsOneWidget);
    });

    testWidgets('releasing Ctrl clears it', (tester) async {
      final instance = await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      await hover(tester, centreOfCell(tester, 8, 0));
      await pressCtrl(tester);
      expect(instance.controller.underlines, hasLength(1));

      await releaseCtrl(tester);

      expect(instance.controller.underlines, isEmpty);
      expect(find.textContaining('click to'), findsNothing);
      expect(cursor(tester), SystemMouseCursors.text);
    });

    testWidgets('pressing Ctrl again lights it up again', (tester) async {
      // The "this cell has been answered" memory has to be dropped with the
      // underline, or the second press would find nothing to do.
      final instance = await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      await hover(tester, centreOfCell(tester, 8, 0));
      await pressCtrl(tester);
      await releaseCtrl(tester);

      await pressCtrl(tester);

      expect(instance.controller.underlines, hasLength(1));
    });

    testWidgets('a word that is not a path underlines nothing', (tester) async {
      final instance = await pumpWithOutput(tester, 'git status --porcelain');
      await hover(tester, centreOfCell(tester, 1, 0));

      await pressCtrl(tester);

      expect(instance.controller.underlines, isEmpty);
      expect(actions.probed, isEmpty, reason: 'no separator, so no candidate');
      expect(cursor(tester), SystemMouseCursors.text);
    });

    testWidgets('moving off the link clears it', (tester) async {
      final instance = await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      final mouse = await hover(tester, centreOfCell(tester, 8, 0));
      await pressCtrl(tester);
      expect(instance.controller.underlines, hasLength(1));

      await mouse.moveTo(centreOfCell(tester, 1, 0));
      await tester.pumpAndSettle();

      expect(instance.controller.underlines, isEmpty);
    });
  });

  group('what a click opens', () {
    testWidgets('a file goes to the editor seam', (tester) async {
      await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      final target = centreOfCell(tester, 8, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.opened, [
        (resolvedMain, TerminalPathKind.file, null, null),
      ]);
      expect(actions.openedUrls, isEmpty);
    });

    testWidgets('path:line:col carries the location through', (tester) async {
      // Nothing honours it yet; it must still arrive at the opener, or
      // honouring it later means re-parsing the text.
      await pumpWithOutput(tester, 'at lib/main.dart:42:7 failed');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      final target = centreOfCell(tester, 6, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.opened, [(resolvedMain, TerminalPathKind.file, 42, 7)]);
    });

    testWidgets('a directory goes to the file manager, not the editor', (
      tester,
    ) async {
      await pumpWithOutput(tester, r'cd C:\src\app\lib');
      actions.exists[r'C:\src\app\lib'] = TerminalPathKind.directory;
      final target = centreOfCell(tester, 8, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);
      expect(find.textContaining('click to reveal'), findsOneWidget);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.opened, [
        (r'C:\src\app\lib', TerminalPathKind.directory, null, null),
      ]);
    });

    testWidgets('a URL keeps going to the browser', (tester) async {
      await pumpWithOutput(tester, 'see https://example.com/a');
      final target = centreOfCell(tester, 6, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);
      // A URL is decided from the text alone; nothing is stat'd for it.
      expect(actions.probed, isEmpty);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.openedUrls, ['https://example.com/a']);
      expect(actions.opened, isEmpty);
    });

    testWidgets('a path that is not there does nothing, visibly or otherwise', (
      tester,
    ) async {
      // `exists` is empty, so the probe says "nothing there". A wrong thing
      // opened is far worse than a word that turns out not to be a link.
      final instance = await pumpWithOutput(tester, 'edit lib/gone.dart now');
      final target = centreOfCell(tester, 8, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      expect(actions.probed, [r'C:\src\app\lib\gone.dart']);
      expect(instance.controller.underlines, isEmpty);
      expect(cursor(tester), SystemMouseCursors.text);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.opened, isEmpty);
      expect(actions.openedUrls, isEmpty);
    });

    testWidgets('a plain click opens nothing', (tester) async {
      // A click in a terminal places a selection, and when the program has
      // asked for mouse reporting it is an event the program receives.
      await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      final target = centreOfCell(tester, 8, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);
      await releaseCtrl(tester);

      await ctrlClick(tester, mouse, target);

      expect(actions.opened, isEmpty);
    });

    testWidgets('Ctrl+click away from the link opens nothing', (tester) async {
      await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      final mouse = await hover(tester, centreOfCell(tester, 8, 0));
      await pressCtrl(tester);
      final elsewhere = centreOfCell(tester, 1, 0);
      await mouse.moveTo(elsewhere);
      await tester.pumpAndSettle();

      await ctrlClick(tester, mouse, elsewhere);
      await releaseCtrl(tester);

      expect(actions.opened, isEmpty);
    });

    testWidgets('an opener that fails says so', (tester) async {
      await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      actions.error = 'No code editor set. Pick one in Settings.';
      final target = centreOfCell(tester, 8, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(find.textContaining('No code editor set'), findsOneWidget);
    });
  });

  group('OSC 8', () {
    /// `OSC 8 ; params ; uri ST label OSC 8 ; ; ST` — a program saying outright
    /// that these cells are a link, rather than leaving it to be recognised.
    String osc8(String uri, String label) =>
        '\x1b]8;;$uri\x1b\\$label\x1b]8;;\x1b\\';

    /// The hyperlink xterm2 is painting as active, which is the affordance for
    /// an `OSC 8` link — this side deliberately draws no rule of its own.
    int? activeHyperlink(WidgetTester tester) => tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal
        .activeHyperlinkId;

    testWidgets('a label that is not the URL is offered and opens', (
      tester,
    ) async {
      // The case the text scan cannot reach at all: the only thing printed is
      // the word `docs`.
      await pumpWithOutput(
        tester,
        'see ${osc8('https://example.com/a', 'docs')} for more',
      );
      final target = centreOfCell(tester, 5, 0);
      final mouse = await hover(tester, target);

      await pressCtrl(tester);

      expect(cursor(tester), SystemMouseCursors.click);
      expect(
        find.textContaining('https://example.com/a'),
        findsOneWidget,
        reason: 'the hint names the URL, which the screen does not',
      );

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.openedUrls, ['https://example.com/a']);
      expect(actions.probed, isEmpty, reason: 'a URL is never stat’d');
    });

    testWidgets('the affordance is xterm2’s, not a second one beside it', (
      tester,
    ) async {
      final instance = await pumpWithOutput(
        tester,
        'see ${osc8('https://example.com/a', 'docs')} for more',
      );
      await hover(tester, centreOfCell(tester, 5, 0));

      await pressCtrl(tester);

      expect(
        activeHyperlink(tester),
        isNotNull,
        reason: 'the painter underlines the run it already knows about',
      );
      expect(
        instance.controller.underlines,
        isEmpty,
        reason: 'so nothing here anchors a second rule over the same text',
      );
    });

    testWidgets('with Ctrl up it is inert like everything else', (
      tester,
    ) async {
      await pumpWithOutput(
        tester,
        'see ${osc8('https://example.com/a', 'docs')} for more',
      );
      final target = centreOfCell(tester, 5, 0);
      final mouse = await hover(tester, target);

      expect(cursor(tester), SystemMouseCursors.text);
      expect(find.textContaining('click to'), findsNothing);

      await ctrlClick(tester, mouse, target);

      expect(actions.openedUrls, isEmpty);
    });

    testWidgets('a scheme that is not http(s) is not made clickable', (
      tester,
    ) async {
      // Terminal output is untrusted, and an `OSC 8` URI is as untrusted as
      // the rest of it.
      await pumpWithOutput(tester, 'see ${osc8('vscode://file/c', 'open')}!');
      final target = centreOfCell(tester, 5, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      expect(cursor(tester), SystemMouseCursors.text);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.openedUrls, isEmpty);
      expect(actions.opened, isEmpty);
    });

    testWidgets('a hyperlinked path still opens as a path', (tester) async {
      // `ls --hyperlink` labels the path with itself, so the text scan finds
      // it — and the scan is what resolves it against the pane's directory,
      // which a `file://` URI could not be trusted to do for a WSL or SSH
      // pane. So the two coexist: the id is not http(s), the text is a path.
      await pumpWithOutput(
        tester,
        'edit ${osc8('file:///c/src/app/lib/main.dart', 'lib/main.dart')} now',
      );
      actions.exists[resolvedMain] = TerminalPathKind.file;
      final target = centreOfCell(tester, 8, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(actions.opened, [
        (resolvedMain, TerminalPathKind.file, null, null),
      ]);
      expect(actions.openedUrls, isEmpty);
    });

    testWidgets('moving off it clears the offer', (tester) async {
      await pumpWithOutput(
        tester,
        'see ${osc8('https://example.com/a', 'docs')} for more',
      );
      final mouse = await hover(tester, centreOfCell(tester, 5, 0));
      await pressCtrl(tester);
      expect(cursor(tester), SystemMouseCursors.click);

      await mouse.moveTo(centreOfCell(tester, 1, 0));
      await tester.pumpAndSettle();

      expect(cursor(tester), SystemMouseCursors.text);
      expect(find.textContaining('click to'), findsNothing);
    });
  });

  testWidgets('one candidate is probed once, however far you slide along it', (
    tester,
  ) async {
    await pumpWithOutput(tester, 'edit lib/main.dart now');
    actions.exists[resolvedMain] = TerminalPathKind.file;
    final mouse = await hover(tester, centreOfCell(tester, 5, 0));
    await pressCtrl(tester);

    for (final column in [6, 7, 8, 9, 10, 11]) {
      await mouse.moveTo(centreOfCell(tester, column, 0));
      await tester.pumpAndSettle();
    }
    await releaseCtrl(tester);

    expect(actions.probed, [resolvedMain]);
  });
}

/// A [TerminalLinkActions] that records instead of doing.
class _RecordingLinkActions implements TerminalLinkActions {
  /// What the host is pretending to have. Anything else is "not there".
  final Map<String, TerminalPathKind> exists = {};

  final List<String> openedUrls = [];
  final List<String> probed = [];
  final List<(String, TerminalPathKind, int?, int?)> opened = [];

  /// What [open] reports back, or null when it worked.
  String? error;

  @override
  Future<void> openUrl(String url) async => openedUrls.add(url);

  @override
  Future<TerminalPathKind?> kindOf(String hostPath) async {
    probed.add(hostPath);
    return exists[hostPath];
  }

  @override
  Future<String?> open(
    String hostPath,
    TerminalPathKind kind, {
    int? line,
    int? column,
  }) async {
    opened.add((hostPath, kind, line, column));
    return error;
  }
}
