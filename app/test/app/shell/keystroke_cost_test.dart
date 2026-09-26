@Tags(['cost'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/status_bar.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/activity_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:path/path.dart' as p;
import 'package:xterm2/xterm.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../support/test_machine.dart';

/// **What one keystroke into a focused terminal pane costs the app around it.**
///
/// The report is the owner's: *"terminal typing started lagging again"*, on
/// 1.6.0 with live sessions. "Again" is the whole reason this file exists —
/// two earlier lags were traced and fixed (a full CLI-store re-scan per slow
/// slot, and the conversation being built behind the terminal in an
/// `IndexedStack`), and each was found by pricing one user gesture in *counts*.
/// This prices the smallest gesture there is.
///
/// Counted, never timed, for the reason `session_switch_cost_test.dart` and
/// `layout_save_cost_test.dart` both give: the suite runs at
/// `--concurrency=4`, so a wall-clock assertion over a few milliseconds is a
/// coin toss — while the units that matter (widget builds, provider builds,
/// database statements, transcript subscriptions, screen scans) are all
/// countable directly.
///
/// ## Why the *whole app* is mounted
///
/// This is the gap that let the regression in. Each of 1.5.0/1.6.0's new live
/// surfaces — the usage chip, the model chip, the activity strip, the clickable
/// transcript paths — shipped with its own cost test, and every one of them
/// passed, because every one of them measured its feature *alone*. Nobody
/// measured them **together, with a terminal pane focused**, which is the state
/// the app is in for most of its working life. So this file mounts
/// `KarmashalaApp`, gives two sessions live panes, lands on one of their
/// terminals, and types.
///
/// ## The two halves of a keystroke
///
/// A key pressed in a pane is really two events, and they are measured apart
/// because they fail differently:
///
/// 1. **The press.** The key travels the focus chain — the pane's copy/interrupt
///    hook, `onPaneKey`, the app's skip-list — and xterm hands it to the PTY.
///    Nothing in the app should build.
/// 2. **The echo.** The shell writes the character back, the PTY coalescer
///    hands it to `Terminal.write` once per frame, and xterm repaints. The
///    terminal's own render is the *whole* legitimate bill; anything else that
///    wakes is paying for a character.
///
/// The budget for both is the same and it is not a soft one: **a keystroke
/// costs the terminal's own render and essentially nothing else.** No database
/// statement, no transcript subscription, no screen scan, no provider build,
/// and no widget build outside the terminal subtree.
///
/// ## What it found (2026-09-02)
///
/// A keystroke, its echo, an eighteen-character burst and a second of idle time
/// all cost **zero** — no statement, no provider build, no widget build outside
/// the terminal, no screen scan, no process. Every suspect that shipped in
/// 1.5.0/1.6.0 is exonerated as a per-keystroke cost by those numbers: the
/// status bar's usage and model chips, the activity strip, the clickable
/// transcript paths, the agent status rules and the session stats readers.
///
/// What was actually running under the keystrokes was invisible.
/// `WorkbenchView` keeps a conversation that has been *asked for* mounted
/// behind the terminal so the toggle preserves its scroll position — and the
/// mounted view kept `sessionChatTranscriptProvider` polling. One tick of that
/// poll on the owner's own largest transcript is **43.8 MB over 11 637 lines,
/// 888 ms** of `jsonDecode` on the UI isolate, every two seconds, against a
/// file the agent being typed to is still writing. See
/// `chatTranscriptPollingProvider`, and the two cases at the bottom of this
/// file that pin both halves: it stops working, and it is still there.
void main() {
  late CountingMachine db;
  late FakeDataServer server;
  late Override data;
  late FakeCommandRunner git;
  late _Rebuilds rebuilds;
  late _WidgetBuilds widgets;
  late ProviderContainer container;
  final terminals = <String, _TailCountingTerminal>{};

  /// Every session whose agent transcript was subscribed to, in order.
  ///
  /// One entry is one CLI store scan plus one whole-file JSONL parse — see
  /// `sessionChatTranscriptProvider`, which does both on creation and is
  /// `autoDispose`. Counted through an override rather than run, because
  /// running it needs the real store and a two-second poll timer. On the
  /// owner's machine the largest is 43.8 MB over 11 637 lines.
  final chatSubscriptions = <String>[];

  /// The transcript streams currently **live**, by session — one entry is one
  /// two-second poll running, and each of its ticks is a whole-file read and
  /// JSON parse of that session's transcript on the UI isolate.
  ///
  /// Held rather than counted, so a test can both ask whether a poll is still
  /// running and deliver one of its ticks.
  final chatStreams = <String, StreamController<List<TranscriptMessage>>>{};

  /// The agent status streams, by session, so a test can say "this agent is
  /// working" — which is what puts a call on the activity strip.
  final statusStreams = <String, StreamController<AgentStatusReport>>{};

  /// What the pane handed to its process — the bytes a real pane would write to
  /// the PTY. See the guard in [mountAndFocus].
  final typed = <String>[];

  setUp(() async {
    db = CountingMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    terminals.clear();
    chatSubscriptions.clear();
    chatStreams.clear();
    statusStreams.clear();
    typed.clear();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    // Two running sessions in one repository — the owner's own workspace —
    // plus a third nothing in this file ever touches, which is what makes a
    // fan-out visible as a per-row bill.
    for (final id in ['s1', 's2', 's3']) {
      db.server.sessionRows.insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session $id',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: 'ext-$id',
        ),
      );
    }
    git = FakeCommandRunner();
    rebuilds = _Rebuilds();
    widgets = _WidgetBuilds();
    container = ProviderContainer(
      observers: [rebuilds],
      overrides: [
        data,
        ...fakeTerminalOverrides(
          machine: db,
          instanceFactory: _countingFactory(terminals),
        ),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        hostCommandRunnerProvider.overrideWithValue(git),
        // Counted rather than run: the real one scans the CLI store, reads a
        // multi-megabyte JSONL and then polls it on a two-second timer, none of
        // which a widget test may do. What it costs is not in dispute; whether
        // a keystroke starts one is the measurement.
        sessionChatTranscriptProvider.overrideWith((ref, sessionId) {
          chatSubscriptions.add(sessionId);
          final poll = StreamController<List<TranscriptMessage>>();
          chatStreams[sessionId] = poll;
          ref.onDispose(() {
            chatStreams.remove(sessionId);
            unawaited(poll.close());
          });
          poll.add(const <TranscriptMessage>[]);
          return poll.stream;
        }),
        // Real hosts and real timers, neither of which a widget test may have.
        // Deliberately **not** overridden: the model chip, the delivery
        // providers and the session verdict — those are among the suspects, so
        // they run.
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        agentSessionStatusProvider.overrideWith((ref, id) {
          final reports = StreamController<AgentStatusReport>();
          statusStreams[id] = reports;
          ref.onDispose(() {
            statusStreams.remove(id);
            unawaited(reports.close());
          });
          return reports.stream;
        }),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        importedTranscriptProvider.overrideWith(
          (ref, _) => Stream.value(const []),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(widgets.stop);
  });

  /// A bounded settle. `pumpAndSettle` never returns against the whole shell —
  /// something always has a frame scheduled — and the measurement only needs
  /// the work a gesture queues to have drained, which a fixed run of frames
  /// does deterministically.
  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Mounts the whole app, gives `s1` and `s2` a live pane each, opens `s1` and
  /// leaves its terminal focused — the state the owner types in.
  Future<TerminalInstance> mountAndFocus(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Registered after the container's own teardown, so it runs before it:
    // disposing the container under a live tree leaves widgets calling into
    // providers that are already gone.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    for (final id in ['s1', 's2']) {
      controller.openTab(TerminalProfile.powerShell);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      db.server.sessionRows.updatePaneId(id, paneId);
    }
    container.read(selectedRepositoryIdProvider.notifier).select('r1');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await settle(tester);
    // The Explorer draws a card per session, and each card is a fistful of
    // per-session providers. A tree nobody has opened would hide the whole
    // per-row half of the bill.
    await tester.tap(find.text('Demo'));
    await settle(tester);
    await container.read(explorerActionsProvider).openNative('s1');
    await settle(tester);

    final paneId = db.server.sessionRows.getById('s1')!.paneId!;
    final instance = controller.instanceFor(paneId)!;
    // The guard against a false green, and the reason this file can claim a
    // zero at all: a fake pane has no PTY, so without this nothing proves the
    // key travelled the focus chain, xterm's shortcut manager and
    // `Terminal.keyInput` at all rather than being swallowed on the way. What
    // a real pane hands to `Pty.write`, this collects.
    instance.terminal.onOutput = typed.add;
    instance.focusNode.requestFocus();
    await settle(tester);
    expect(
      instance.focusNode.hasFocus,
      isTrue,
      reason: 'the measurement is about a pane you are typing into',
    );
    expect(
      container.read(terminalVisibleProvider),
      isTrue,
      reason: 'the terminal is the surface in front of the user',
    );
    // One warm keystroke before anything is counted. The *first* key event of a
    // run moves Flutter's own `FocusManager.highlightMode` from `touch` to
    // `traditional`, and every `InkWell` in the tree listens to that — 52 of
    // them here, 520 widget builds. It is the framework's, it happens once per
    // app launch, and counting it would price a transition the user pays for
    // when they first touch the keyboard and never again.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await settle(tester);
    expect(
      typed,
      isNotEmpty,
      reason:
          'nothing below means anything unless a key press actually reaches '
          'the terminal: a zero for a keystroke that never arrived is not a '
          'measurement',
    );
    return instance;
  }

  int encodes() => terminals.values.fold(0, (sum, t) => sum + t.bufferReads);

  int tailScans() => terminals.values.fold(0, (sum, t) => sum + t.tailReads);

  void reset() {
    db.reset();
    rebuilds.reset();
    widgets.reset();
    git.requests.clear();
    chatSubscriptions.clear();
    ShellStatusBar.debugItemBuildCount = 0;
    ModelChip.debugBuildCount = 0;
  }

  void report(String label, int encodesBefore, int tailsBefore) {
    // ignore: avoid_print
    print(
      '$label statements=${db.count} rebuilds=${rebuilds.total} '
      'widgetBuilds=${widgets.total} outsideTerminal=${widgets.outsideTotal} '
      'chatTranscripts=${chatSubscriptions.length}$chatSubscriptions '
      'processes=${git.requests.length} '
      'encodes=${encodes() - encodesBefore} '
      'tailScans=${tailScans() - tailsBefore} '
      'statusBarItems=${ShellStatusBar.debugItemBuildCount} '
      'modelChips=${ModelChip.debugBuildCount}',
    );
    if (db.count > 0) {
      // ignore: avoid_print
      print('$label-SQL ${_tally(db.statements)}');
    }
    if (rebuilds.total > 0) {
      // ignore: avoid_print
      print('$label-PROVIDERS ${rebuilds.report}');
    }
    if (widgets.total > 0) {
      // ignore: avoid_print
      print('$label-WIDGETS ${widgets.report}');
    }
  }

  /// Everything a keystroke must not do, asserted in one place so the three
  /// cases below read as one budget rather than three opinions.
  void expectNothingButTheTerminal(String label) {
    expect(
      chatSubscriptions,
      isEmpty,
      reason:
          '$label: each entry is one CLI store scan plus one whole-transcript '
          'JSONL parse — 43.8 MB on the owner\'s machine — for a surface that is '
          'not even on screen: $chatSubscriptions',
    );
    expect(
      db.count,
      0,
      reason:
          '$label: typing a character says nothing about any row, so it must '
          'reach the database not at all: ${_tally(db.statements)}',
    );
    expect(
      git.requests,
      isEmpty,
      reason: '$label: typing must start no process',
    );
    expect(
      tailScans(),
      0,
      reason:
          '$label: walking a pane\'s screen is the status registry\'s job, on '
          'its own timer — a keystroke must not trigger one',
    );
    expect(
      rebuilds.total,
      0,
      reason:
          '$label: no provider may wake for a character: ${rebuilds.report}',
    );
    expect(
      widgets.outsideTotal,
      0,
      reason:
          '$label: the terminal\'s own render is the whole legitimate bill; '
          'everything here is the app around it paying for a character: '
          '${widgets.outsideReport}',
    );
    expect(
      ShellStatusBar.debugItemBuildCount,
      0,
      reason: '$label: the status bar knows nothing about what you typed',
    );
    expect(
      ModelChip.debugBuildCount,
      0,
      reason: '$label: the model chip knows nothing about what you typed',
    );
  }

  testWidgets('one key pressed in a focused pane wakes nothing', (
    tester,
  ) async {
    await mountAndFocus(tester);
    reset();
    final encodesBefore = encodes();
    final tailsBefore = tailScans();
    widgets.start();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();

    widgets.stop();
    report('KEYSTROKE-PRESS', encodesBefore, tailsBefore);
    expectNothingButTheTerminal('a key press');
    expect(
      encodes() - encodesBefore,
      0,
      reason: 'no pane moved, so no scrollback may be re-encoded',
    );
  });

  testWidgets('the echo of one character wakes nothing but the terminal', (
    tester,
  ) async {
    // The other half. A fake pane has no PTY, so the shell's echo is delivered
    // the way a real one's is — through the instance, into `Terminal.write` —
    // and then a frame is pumped, which is when xterm repaints.
    final instance = await mountAndFocus(tester);
    reset();
    final encodesBefore = encodes();
    final tailsBefore = tailScans();
    widgets.start();

    (instance as FakeTerminalInstance).receive('a');
    await tester.pump();

    widgets.stop();
    report('KEYSTROKE-ECHO', encodesBefore, tailsBefore);
    expectNothingButTheTerminal('an echoed character');
  });

  testWidgets('a burst of typing costs a multiple of one character', (
    tester,
  ) async {
    // The property that makes lag *feel* like lag: whatever one character
    // costs, twenty must cost twenty of it and not twenty squared. A cost that
    // walks the buffer, or that re-derives anything from the whole screen,
    // fails here long before it fails above.
    final instance = await mountAndFocus(tester) as FakeTerminalInstance;
    reset();
    final encodesBefore = encodes();
    final tailsBefore = tailScans();
    widgets.start();

    for (final letter in 'git status --short'.split('')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      instance.receive(letter);
      await tester.pump();
    }

    widgets.stop();
    report('KEYSTROKE-BURST', encodesBefore, tailsBefore);
    expectNothingButTheTerminal('a burst of typing');
  });

  testWidgets('the app at rest costs nothing at all', (tester) async {
    // The control. Everything above measures a keystroke against a baseline of
    // "nothing happening", and that baseline is only worth anything if it is
    // genuinely nothing: an app that rebuilds a chip every frame while idle
    // makes typing feel slow without a single count being attributable to a
    // key.
    await mountAndFocus(tester);
    reset();
    final encodesBefore = encodes();
    final tailsBefore = tailScans();
    widgets.start();

    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    widgets.stop();
    report('IDLE-60-FRAMES', encodesBefore, tailsBefore);
    expect(
      widgets.total,
      0,
      reason:
          'a second of an idle window must build nothing: ${widgets.report}',
    );
    expect(rebuilds.total, 0, reason: rebuilds.report);
    expect(db.count, 0, reason: _tally(db.statements));
  });

  testWidgets('a conversation behind the terminal stops polling', (
    tester,
  ) async {
    // **The measurement that names the lag.**
    //
    // Everything above is zero, and that is the finding: the app around a
    // focused pane does nothing at all for a keystroke. What it does do while
    // you type is invisible — `WorkbenchView` keeps a conversation that has
    // been *asked for* mounted behind the terminal, on purpose, because the
    // `IndexedStack` is what preserves its scroll position across the toggle.
    // Underneath that mounted view `sessionChatTranscriptProvider` goes on
    // polling every two seconds, and every tick whose file has moved reads and
    // JSON-decodes that session's **whole** transcript on the UI isolate. The
    // owner's largest is 43.8 MB, and it moves constantly, because the agent
    // writing it is the one they are typing to.
    //
    // So: mounted, yes — the feature is not removed and the scroll position is
    // still there. Working, no.
    final instance = await mountAndFocus(tester) as FakeTerminalInstance;
    await tester.tap(find.byTooltip('Chat view'));
    await settle(tester);
    expect(
      find.byType(SessionTranscriptView),
      findsOneWidget,
      reason: 'the guard against a false green: the conversation really opened',
    );
    expect(
      container.read(chatTranscriptPollingProvider),
      isTrue,
      reason: 'the conversation is the surface in front, so it must be live',
    );

    await tester.tap(find.byTooltip('Terminal view'));
    await settle(tester);
    instance.focusNode.requestFocus();
    await settle(tester);

    // ignore: avoid_print
    print(
      'CHAT-BEHIND-TERMINAL polling='
      '${container.read(chatTranscriptPollingProvider)} '
      'stillMounted=${chatStreams.containsKey('s1')}',
    );
    expect(
      container.read(terminalVisibleProvider),
      isTrue,
      reason: 'the terminal is the surface in front of the user again',
    );
    expect(
      container.read(chatTranscriptPollingProvider),
      isFalse,
      reason:
          'a whole-transcript read and JSON parse on the UI isolate every two '
          'seconds, for a surface nobody can see, under every keystroke',
    );
    // ...and the other half of the rule: the conversation is still *there*, so
    // switching back to it is instant and keeps its place. A cost test that
    // passed because the feature stopped working would be worse than the cost.
    expect(
      chatStreams.keys,
      contains('s1'),
      reason:
          'the conversation stays mounted behind the terminal — that is what '
          'keeps its scroll position — it simply stops working',
    );
  });

  testWidgets('and starts again the moment it is looked at', (tester) async {
    await mountAndFocus(tester);
    await tester.tap(find.byTooltip('Chat view'));
    await settle(tester);
    await tester.tap(find.byTooltip('Terminal view'));
    await settle(tester);
    expect(container.read(chatTranscriptPollingProvider), isFalse);

    await tester.tap(find.byTooltip('Chat view'));
    await settle(tester);

    expect(
      container.read(chatTranscriptPollingProvider),
      isTrue,
      reason:
          'pausing a poll that never resumes is not a performance fix, it is a '
          'broken conversation',
    );
  });

  testWidgets('nothing behind the terminal ticks either', (tester) async {
    // The other half of "mounted is not working". The activity strip counts the
    // elapsed time of an outstanding tool call on a one-second `Timer.periodic`,
    // and its own cost test measured it with the conversation *visible* — the
    // case it could not see is this one: the strip left behind the terminal,
    // calling `setState` once a second and laying itself out under every
    // keystroke going into the pane in front of it.
    //
    // Both halves are asserted together on purpose. Stopping the transcript
    // poll and leaving a timer running would still be work for a surface
    // nobody can see, and one gate passing is not the property.
    final instance = await mountAndFocus(tester) as FakeTerminalInstance;
    await tester.tap(find.byTooltip('Chat view'));
    await settle(tester);
    statusStreams['s1']!.add(
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 's1',
        status: AgentActivityStatus.working,
        source: AgentStatusSource.hook,
        observedAt: testTime,
      ),
    );
    await settle(tester);
    chatStreams['s1']!.add([
      TranscriptMessage(
        role: 'tool',
        text: 'Bash(git status)',
        at: testTime.subtract(const Duration(seconds: 30)),
        pendingToolUseId: 'call-1',
        tool: const ToolActivity(name: 'Bash', subject: 'git status'),
      ),
    ]);
    await settle(tester);
    expect(
      find.byType(ActivityStrip),
      findsOneWidget,
      reason: 'the guard against a false green: the strip really is drawn',
    );
    expect(
      tester.getSize(find.byType(ActivityStrip)).height,
      greaterThan(0),
      reason: 'a call is outstanding, so the strip has something to count',
    );

    await tester.tap(find.byTooltip('Terminal view'));
    await settle(tester);
    instance.focusNode.requestFocus();
    // One warm keystroke, for the reason [mountAndFocus] gives: the taps above
    // put Flutter's own focus highlight back into `touch`, and the next key
    // press moves every `InkWell` in the tree back to `traditional` once.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await settle(tester);
    reset();
    final encodesBefore = encodes();
    final tailsBefore = tailScans();
    widgets.start();

    // Three seconds of app time — three of the strip's ticks — with the user
    // typing throughout, which is the shape of the complaint.
    for (var i = 0; i < 180; i++) {
      if (i % 30 == 0) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        instance.receive('a');
      }
      await tester.pump(const Duration(milliseconds: 16));
    }

    widgets.stop();
    report('TYPING-WITH-A-CONVERSATION-BEHIND', encodesBefore, tailsBefore);
    expect(
      widgets.outsideTotal,
      0,
      reason:
          'three seconds of typing with a conversation mounted behind the '
          'terminal: ${widgets.outsideReport}',
    );
    expect(rebuilds.total, 0, reason: rebuilds.report);
    expect(db.count, 0, reason: _tally(db.statements));
  });

  group('the poll itself', () {
    // The whole-app cases above pin *when* the gate is open. These pin that the
    // stream actually consults it — that the pause is a pause of the read and
    // not merely of a boolean nobody reads. Real file, real timers, driven at
    // an interval a test can wait for through the same seam
    // `deliveryPollIntervalProvider` and `usageRefreshIntervalProvider` expose.
    late Directory dir;
    late File transcript;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('karmashala-chat-poll');
      transcript = File(p.join(dir.path, 'session.jsonl'))
        ..writeAsStringSync(_claudeLine('first'));
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can still hold the handle; the temp directory is disposable.
      }
    });

    /// Waits until [check] holds, or gives up. Condition-based rather than a
    /// fixed sleep: the poll is on a real timer, and a fixed wait either flakes
    /// or is slow.
    Future<bool> waitFor(bool Function() check) async {
      for (var i = 0; i < 200; i++) {
        if (check()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return check();
    }

    ProviderContainer pollingContainer({required bool terminalVisible}) {
      final container = ProviderContainer(
        overrides: [
          data,
          ...fakeTerminalOverrides(machine: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          chatTranscriptPollIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 5),
          ),
          sessionTranscriptLocatorProvider.overrideWith(
            (ref) => _FixedLocator(ref, transcript.path),
          ),
        ],
      );
      addTearDown(container.dispose);
      // A face belongs to a workspace group now, and this container has no
      // widget tree — so it names one and the poll gate reads "any group on
      // chat", which is the same question with one group.
      container
          .read(terminalFacesProvider.notifier)
          .show('g', terminal: terminalVisible);
      return container;
    }

    test('reads the transcript while the conversation is in front', () async {
      final container = pollingContainer(terminalVisible: false);
      final seen = <List<TranscriptMessage>>[];
      final sub = container.listen(sessionChatTranscriptProvider('s1'), (
        _,
        next,
      ) {
        final value = next.asData?.value;
        if (value != null && value.isNotEmpty) seen.add(value);
      }, fireImmediately: true);
      addTearDown(sub.close);

      expect(
        await waitFor(() => seen.isNotEmpty),
        isTrue,
        reason: 'the guard against a false green: the poll has to work at all',
      );

      final before = seen.length;
      transcript.writeAsStringSync(
        '${_claudeLine('first')}${_claudeLine('second')}',
      );
      expect(
        await waitFor(() => seen.length > before),
        isTrue,
        reason: 'a visible conversation follows its file',
      );
    });

    test('reads nothing at all while the terminal is in front', () async {
      final container = pollingContainer(terminalVisible: true);
      final seen = <List<TranscriptMessage>>[];
      final sub = container.listen(sessionChatTranscriptProvider('s1'), (
        _,
        next,
      ) {
        final value = next.asData?.value;
        if (value != null && value.isNotEmpty) seen.add(value);
      }, fireImmediately: true);
      addTearDown(sub.close);

      // Long enough for ~40 ticks at the 5 ms interval this container polls at.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      transcript.writeAsStringSync(
        '${_claudeLine('first')}${_claudeLine('second')}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // ignore: avoid_print
      print('CHAT-POLL-PAUSED reads=${seen.length}');
      expect(
        seen,
        isEmpty,
        reason:
            'the terminal is the surface in front, so not one whole-transcript '
            'read may happen under the keystrokes going into it',
      );

      // ...and it is a pause, not a stop: looking at the conversation brings it
      // back on the next tick.
      container.read(terminalFacesProvider.notifier).show('g', terminal: false);
      expect(
        await waitFor(() => seen.isNotEmpty),
        isTrue,
        reason: 'a paused poll that never resumes is a broken conversation',
      );
    });
  });
}

/// One Claude Code transcript line, in the shape `readCliTranscript` parses.
String _claudeLine(String text) =>
    '${jsonEncode({
      'type': 'user',
      'timestamp': testTime.toIso8601String(),
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    })}\n';

/// A locator that already knows where the file is, so the poll under test is
/// the *read* loop rather than the store scan in front of it.
class _FixedLocator extends SessionTranscriptLocator {
  _FixedLocator(super.ref, this.path);

  final String path;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => path;

  @override
  Future<Map<String, String>> index() async => {'x': path};
}

/// Counts every provider build and rebuild, by provider.
///
/// Riverpod carries no variable name into a `ProviderBase`, so a provider is
/// reported by its runtime type and family argument —
/// `Provider<ReviewOffer>(s2)` — which names every one in this app.
final class _Rebuilds extends ProviderObserver {
  final Map<String, int> counts = {};

  int get total => counts.values.fold(0, (a, b) => a + b);

  void reset() => counts.clear();

  void _bump(ProviderObserverContext context) {
    final provider = context.provider;
    final argument = provider.from == null ? '' : '(${provider.argument})';
    final name = '${provider.runtimeType}$argument';
    counts[name] = (counts[name] ?? 0) + 1;
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) =>
      _bump(context);

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) => _bump(context);

  String get report {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => '${e.key}=${e.value}').join(' | ');
  }
}

/// Counts **every widget build in the tree**, by widget type, and separates
/// the terminal's own from everything else.
///
/// `debugOnRebuildDirtyWidget` is the framework's own hook, called once per
/// element that actually rebuilds — so this is not a proxy for widget work, it
/// is the count itself. Nothing has to be added to the app to be measured,
/// which matters for a file whose job is to price code it does not own.
///
/// The split is by widget type rather than by subtree because a rebuild's
/// *cost* is the widget's own build method, and the question this file asks is
/// "what, other than the terminal, ran". xterm's own widgets and the pane
/// wrapper that hosts them are the legitimate half; every other name in the
/// report is the app paying for a character.
class _WidgetBuilds {
  final Map<String, int> counts = {};
  bool _running = false;

  static const _terminalOwn = {
    'TerminalView',
    'TerminalPaneView',
    'RenderTerminal',
    'Scrollable',
    'Scrollbar',
    'RawScrollbar',
    'ScrollableViewport',
    'CustomPaint',
    'Viewport',
  };

  static bool _isTerminals(String name) =>
      _terminalOwn.contains(name) ||
      name.startsWith('_Terminal') ||
      name.startsWith('Terminal');

  int get total => counts.values.fold(0, (a, b) => a + b);

  int get outsideTotal => outside.values.fold(0, (a, b) => a + b);

  Map<String, int> get outside => {
    for (final entry in counts.entries)
      if (!_isTerminals(entry.key)) entry.key: entry.value,
  };

  void start() {
    if (_running) return;
    _running = true;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final name = element.widget.runtimeType.toString();
      counts[name] = (counts[name] ?? 0) + 1;
    };
  }

  void stop() {
    if (!_running) return;
    _running = false;
    debugOnRebuildDirtyWidget = null;
  }

  void reset() => counts.clear();

  String _format(Map<String, int> source) {
    final entries = source.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => '${e.key}=${e.value}').join(' | ');
  }

  String get report => _format(counts);

  String get outsideReport => _format(outside);
}

/// The statements issued, tallied by shape, commonest first.
String _tally(List<String> statements) {
  final counts = <String, int>{};
  for (final sql in statements) {
    final flat = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    counts[flat] = (counts[flat] ?? 0) + 1;
  }
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => '${e.value}x ${e.key}').join(' || ');
}

/// A [CountingTerminal] that also counts **screen scans** — reads of the active
/// buffer made by `terminalTailLines`, and not xterm's own reads while it
/// writes or paints.
///
/// The status registry walks a live pane's bottom rows on its own rotation to
/// decide whether the agent is working; `TerminalGridStatusSource` gained a
/// composer-footer check in 1.6.0. This is what prices it, and what proves a
/// keystroke does not trigger one.
class _TailCountingTerminal extends CountingTerminal {
  int tailReads = 0;

  @override
  Buffer get buffer {
    // Attributed, because xterm reads this getter constantly on its own account
    // — every `write`, every paint. Only the app walking the screen is a cost
    // this file is about.
    if (StackTrace.current.toString().contains('terminal_grid_text.dart')) {
      tailReads++;
    }
    return super.buffer;
  }
}

TerminalInstanceFactory _countingFactory(
  Map<String, _TailCountingTerminal> into,
) =>
    ({
      required id,
      required profile,
      workingDirectory,
      restoredScrollback,
      shellIntegration = false,
      agentLaunch,
      adoptTerminal,
    }) {
      final terminal = _TailCountingTerminal()..resize(120, 40);
      if (restoredScrollback != null && restoredScrollback.isNotEmpty) {
        terminal.write(restoredScrollback);
      }
      into[id] = terminal;
      return FakeTerminalInstance(
        id: id,
        title: agentLaunch?.title ?? agentLaunch?.agentId ?? profile.label,
        profileId: agentLaunch?.profileId ?? profile.id,
        workingDirectory: workingDirectory,
        agentLaunch: agentLaunch,
        adoptTerminal: terminal,
      );
    };
