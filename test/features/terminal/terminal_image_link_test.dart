import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/media/application/session_media_providers.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';
import 'package:karmashala/src/features/media/presentation/session_image_dialog.dart';
import 'package:karmashala/src/features/terminal/application/terminal_link_actions.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:xterm2/xterm.dart';

import '../media/session_media_fixture.dart';
import 'fake_instance.dart';

/// Ctrl+clicking the `[Image #6]` an agent CLI prints into a pane.
///
/// The owner's request, verbatim: *"image link inside terminal still not wired,
/// i should be able to ctrl click on the image `[Image #6]` and preview the
/// image in dialog"*.
///
/// It rides the gesture that already exists — Ctrl is the switch, nothing is
/// detected until it is held — so these are the same properties
/// `terminal_link_click_test.dart` pins, asked of a second kind of target. What
/// is different, and is most of this file, is that the reference can name a
/// picture the session does not have. That must be said in words: opening
/// nothing looks broken, and opening the *nearest* picture would be worse than
/// either.
///
/// The lookup itself is a seam here, exactly as [TerminalLinkActions] is: what
/// a number really resolves to against a real transcript is proved in
/// `test/features/media/session_image_lookup_test.dart`.
void main() {
  const sessionId = 'S1';

  late AppDatabase db;
  late Directory dir;
  late File picture;
  late _RecordingLookup lookup;
  late _RecordingLinkActions actions;

  setUp(() {
    db = AppDatabase.memory();
    dir = Directory.systemTemp.createTempSync('terminal_image_link');
    picture = File('${dir.path}/pasted-3.png')..writeAsBytesSync(tinyPngBytes);
    lookup = _RecordingLookup();
    actions = _RecordingLinkActions();
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  /// A container whose one pane belongs to [session] — null for a plain shell,
  /// which is a pane with nothing to resolve a reference against.
  ProviderContainer containerFor({String? session = sessionId}) {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          database: db,
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
                workingDirectory: workingDirectory ?? r'C:\src\app',
                restored: restoredScrollback,
                adoptTerminal: adoptTerminal,
                agentLaunch: session == null
                    ? null
                    : AgentPaneLaunch(
                        agentId: 'claude-code',
                        executable: 'claude',
                        sessionId: session,
                      ),
              ),
        ),
        terminalLinkActionsProvider.overrideWithValue(actions),
        sessionImageLookupProvider.overrideWithValue(lookup.call),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<TerminalInstance> pumpWithOutput(
    WidgetTester tester,
    String output, {
    String? session = sessionId,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = containerFor(session: session);
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

  group('the reference is a target on the gesture that already exists', () {
    testWidgets('holding Ctrl underlines `[Image #6]`', (tester) async {
      final instance = await pumpWithOutput(tester, 'ok [Image #6] pasted');
      await hover(tester, centreOfCell(tester, 6, 0));

      await pressCtrl(tester);

      final highlight = instance.controller.underlines.single;
      // A rule, not a wash: it is an underline the controller carries, and
      // nothing was added to the filled `highlights` list.
      expect(instance.controller.highlights, isEmpty);
      // Exactly `[Image #6]`, which starts at column 3 and is 10 cells long.
      expect(highlight.range!.begin, const CellOffset(3, 0));
      expect(highlight.range!.end, const CellOffset(13, 0));
      expect(cursor(tester), SystemMouseCursors.click);
      expect(find.textContaining('click to preview  [Image #6]'), findsOne);
    });

    testWidgets('with Ctrl up nothing is detected', (tester) async {
      // The rule the whole affordance is built on: the modifier is the switch.
      final instance = await pumpWithOutput(tester, 'ok [Image #6] pasted');

      final mouse = await hover(tester, centreOfCell(tester, 6, 0));
      for (final column in [4, 7, 9, 11]) {
        await mouse.moveTo(centreOfCell(tester, column, 0));
        await tester.pumpAndSettle();
      }

      expect(instance.controller.underlines, isEmpty);
      expect(find.textContaining('click to'), findsNothing);
      expect(cursor(tester), SystemMouseCursors.text);
      expect(lookup.asked, isEmpty);
    });

    testWidgets('releasing Ctrl clears it', (tester) async {
      final instance = await pumpWithOutput(tester, 'ok [Image #6] pasted');
      await hover(tester, centreOfCell(tester, 6, 0));
      await pressCtrl(tester);
      expect(instance.controller.underlines, hasLength(1));

      await releaseCtrl(tester);

      expect(instance.controller.underlines, isEmpty);
      expect(cursor(tester), SystemMouseCursors.text);
    });

    testWidgets('a pane with no session offers nothing', (tester) async {
      // Media is per-session. A plain shell tab has nothing to resolve a
      // number against, so it must not pretend the text is clickable.
      final instance = await pumpWithOutput(
        tester,
        'ok [Image #6] pasted',
        session: null,
      );
      await hover(tester, centreOfCell(tester, 6, 0));

      await pressCtrl(tester);

      expect(instance.controller.underlines, isEmpty);
      expect(cursor(tester), SystemMouseCursors.text);
      expect(find.textContaining('click to'), findsNothing);
    });

    testWidgets('nothing is asked of the store merely by hovering', (
      tester,
    ) async {
      // The reference is unambiguous text the CLI wrote, so it underlines on
      // sight. Reading the transcript is a click's cost, never a hover's.
      await pumpWithOutput(tester, 'ok [Image #6] pasted');
      await hover(tester, centreOfCell(tester, 6, 0));

      await pressCtrl(tester);

      expect(lookup.asked, isEmpty);
    });
  });

  group('what a click opens', () {
    testWidgets('the picture the CLI numbered, in a dialog', (tester) async {
      lookup.answer = SessionImageFound(
        SessionMediaItem(
          id: 'm3',
          origin: SessionMediaOrigin.pasted,
          sequence: 3,
          path: picture.path,
          pasteId: 6,
        ),
      );
      await pumpWithOutput(tester, 'ok [Image #6] pasted');
      final target = centreOfCell(tester, 6, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      // Resolved inside this pane's own session, by the number on screen.
      expect(lookup.asked, [(sessionId, 6)]);
      final dialog = tester.widget<SessionImageDialog>(
        find.byType(SessionImageDialog),
      );
      expect(dialog.item.pasteId, 6);
      expect(dialog.item.path, picture.path);
      expect(dialog.reference, '[Image #6]');
      expect(dialog.matches, 1);
    });

    testWidgets('a number the session used twice says so in the dialog', (
      tester,
    ) async {
      // The CLI restarts its counter when it restarts, so one session can hold
      // several pictures wearing the same number. The newest is right for the
      // process printing into the pane now — but a line scrolled back from an
      // earlier run means an older one, and the pane's text cannot tell. Said
      // out loud rather than passed off as a certainty.
      lookup.answer = SessionImageFound(
        SessionMediaItem(
          id: 'm9',
          origin: SessionMediaOrigin.pasted,
          sequence: 9,
          path: picture.path,
          pasteId: 6,
        ),
        matches: 3,
      );
      await pumpWithOutput(tester, 'ok [Image #6] pasted');
      final target = centreOfCell(tester, 6, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(find.textContaining('used that number 3 times'), findsOne);
      expect(find.textContaining('most recent'), findsOne);
    });

    testWidgets('a number the store has no picture for is refused in words', (
      tester,
    ) async {
      lookup.answer = const SessionImageUnavailable(
        '[Image #9] is not among this session\'s images.',
      );
      await pumpWithOutput(tester, 'ok [Image #9] pasted');
      final target = centreOfCell(tester, 6, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);

      await ctrlClick(tester, mouse, target);
      await releaseCtrl(tester);

      expect(find.byType(SessionImageDialog), findsNothing);
      expect(find.textContaining('is not among'), findsOne);
    });

    testWidgets('a plain click opens nothing', (tester) async {
      await pumpWithOutput(tester, 'ok [Image #6] pasted');
      final target = centreOfCell(tester, 6, 0);
      final mouse = await hover(tester, target);
      await pressCtrl(tester);
      await releaseCtrl(tester);

      await ctrlClick(tester, mouse, target);

      expect(lookup.asked, isEmpty);
      expect(find.byType(SessionImageDialog), findsNothing);
    });
  });

  testWidgets('a path on the same line still opens exactly as before', (
    tester,
  ) async {
    // The reference must not shadow the link kinds that were already there.
    const resolvedMain = r'C:\src\app\lib\main.dart';
    await pumpWithOutput(tester, '[Image #6] see lib/main.dart');
    actions.exists[resolvedMain] = TerminalPathKind.file;
    final target = centreOfCell(tester, 18, 0);
    final mouse = await hover(tester, target);
    await pressCtrl(tester);
    expect(find.textContaining('click to open  $resolvedMain'), findsOne);

    await ctrlClick(tester, mouse, target);
    await releaseCtrl(tester);

    expect(actions.opened, [(resolvedMain, TerminalPathKind.file, null, null)]);
    expect(lookup.asked, isEmpty);
  });
}

/// A [SessionImageLookupFn] that records instead of reading a transcript.
class _RecordingLookup {
  final asked = <(String, int)>[];

  SessionImageLookup answer = const SessionImageUnavailable('nothing here');

  Future<SessionImageLookup> call(String sessionId, int pasteId) async {
    asked.add((sessionId, pasteId));
    return answer;
  }
}

/// A [TerminalLinkActions] that records instead of doing — the same seam
/// `terminal_link_click_test.dart` uses, so no browser, editor or file manager
/// is ever started by a test run.
class _RecordingLinkActions implements TerminalLinkActions {
  final Map<String, TerminalPathKind> exists = {};
  final probed = <String>[];
  final opened = <(String, TerminalPathKind, int?, int?)>[];
  final openedUrls = <String>[];
  String? error;

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

  @override
  Future<void> openUrl(String url) async => openedUrls.add(url);
}
