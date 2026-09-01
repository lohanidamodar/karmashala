import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_link_actions.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'fake_instance.dart';

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

  late AppDatabase db;
  late _RecordingLinkActions actions;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    actions = _RecordingLinkActions();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          database: db,
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
    db.close();
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
      expect(instance.controller.highlights, isEmpty);
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

      final highlight = instance.controller.highlights.single;
      expect(highlight.underline, isTrue, reason: 'a rule, not a wash');
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
      expect(instance.controller.highlights, hasLength(1));

      await releaseCtrl(tester);

      expect(instance.controller.highlights, isEmpty);
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

      expect(instance.controller.highlights, hasLength(1));
    });

    testWidgets('a word that is not a path underlines nothing', (tester) async {
      final instance = await pumpWithOutput(tester, 'git status --porcelain');
      await hover(tester, centreOfCell(tester, 1, 0));

      await pressCtrl(tester);

      expect(instance.controller.highlights, isEmpty);
      expect(actions.probed, isEmpty, reason: 'no separator, so no candidate');
      expect(cursor(tester), SystemMouseCursors.text);
    });

    testWidgets('moving off the link clears it', (tester) async {
      final instance = await pumpWithOutput(tester, 'edit lib/main.dart now');
      actions.exists[resolvedMain] = TerminalPathKind.file;
      final mouse = await hover(tester, centreOfCell(tester, 8, 0));
      await pressCtrl(tester);
      expect(instance.controller.highlights, hasLength(1));

      await mouse.moveTo(centreOfCell(tester, 1, 0));
      await tester.pumpAndSettle();

      expect(instance.controller.highlights, isEmpty);
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
      expect(instance.controller.highlights, isEmpty);
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
