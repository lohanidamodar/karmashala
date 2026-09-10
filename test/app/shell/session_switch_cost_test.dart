@Tags(['cost'])
library;

import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What one session switch costs.**
///
/// The report is the owner's: *"it's lagging again, i only have two sessions
/// active and i switch between them. switching is very laggy."* Two sessions,
/// so this is not a scale problem — it is per-switch work that is large.
///
/// Counted, never timed, for the reason `session_signal_cost_test.dart` and
/// `layout_save_cost_test.dart` both give: the suite runs at
/// `--concurrency=4`, so a wall-clock assertion over a few milliseconds is a
/// coin toss — while the units that matter (database statements, provider
/// builds, transcript subscriptions, subprocesses, scrollback encodes) are all
/// countable directly.
///
/// The **whole app** is mounted, not a slice of it: a switch's bill is spread
/// across the Explorer, the workbench, the session bar and the side panel, and
/// any one of them measured alone looks cheap.
///
/// What it found (2026-09-02), with two live sessions and a third row drawn:
/// **105 statements, 47 provider builds, one whole-transcript read and six
/// dead-pane screen scans**, no subprocess and no scrollback encode — and the
/// bill grew by about one statement per session in the workspace (177 at 20
/// sessions, 257 at 100, 557 at 400). Three things were paying for it, none of
/// them the database itself:
///
/// 1. **The conversation was built behind the terminal.** `WorkbenchView` put
///    both surfaces in an `IndexedStack`, which builds every child, so landing
///    on a session's terminal also mounted its chat view — and
///    `sessionChatTranscriptProvider` is an `autoDispose` family, so every
///    switch started a fresh CLI **store scan** and then read and JSON-parsed
///    that session's **whole transcript file**, for a surface nobody was
///    looking at. Fixed by building the conversation only once it is asked for.
///
/// 2. **The switch named no row.** The workbench published its "the pane on
///    screen moved" change without a session id, which `SessionSignals`
///    correctly reads as "all of them", so every per-session provider in the
///    app rebuilt — five builds and a handful of reads per Explorer card, per
///    switch, for rows nothing had happened to, plus a walk of every drawn
///    dead pane's screen looking for a resume refusal it could not have
///    acquired.
///
/// 3. **The Explorer asked the database where every session lives.** A switch
///    moves placement, the tree watches placement, and the tree is built for
///    every session in the project — only the cards on screen are *inflated* —
///    so `_subPathFor*` cost one `repositories` lookup per session. That is the
///    term that grew.
///
/// After all three: **62 statements, 29 provider builds, no transcript read,
/// no dead-pane scan, nothing at all for a session the switch did not name,
/// and a flat curve — 73 statements whether the workspace holds 20 sessions or
/// 400.**
///
/// What was measured and left alone, because no number justified touching it:
/// the delivery strip, `sessionVerdictProvider` and
/// `ReviewSessionService.offerFor` cost about a dozen indexed row lookups
/// between them and start no process; `checkoutDeliveryProvider` is keyed by
/// checkout and stays warm across a switch, so no git runs; narrowing the
/// session rows' `watch(selectedSessionIdProvider)` to a `select` changed the
/// count by nothing at all, because the panel above them rebuilds wholesale;
/// and `SessionWhereabouts` still has no `==`, so every recompute of it reads
/// downstream as a change. That last one is what makes a dead pane's card walk
/// the pane's screen, and (2) is what stopped a switch asking — so adding
/// equality to the domain type would now move none of these numbers, while
/// changing behaviour anywhere that relies on identity.
void main() {
  late CountingDatabase db;
  late FakeCommandRunner git;
  late _Rebuilds rebuilds;
  late ProviderContainer container;
  final terminals = <String, _TailCountingTerminal>{};

  /// Every session whose agent transcript was subscribed to, in order.
  ///
  /// One entry is one CLI store scan plus one whole-file JSONL parse — see
  /// `sessionChatTranscriptProvider`, which does both on creation and is
  /// `autoDispose`, so leaving a session and coming back pays again. Counted
  /// through an override rather than run, because running it needs the real
  /// store and a two-second poll timer.
  final chatSubscriptions = <String>[];

  setUp(() {
    db = CountingDatabase();
    terminals.clear();
    chatSubscriptions.clear();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    // Two running sessions in one repository — the owner's exact workspace —
    // plus a third the switch never touches, which is what makes a fan-out
    // visible. All carry a CLI id, because that is what makes a chat rendering
    // possible and therefore what makes a transcript worth reading.
    for (final id in ['s1', 's2', 's3']) {
      SessionDao(db).insert(
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
    container = ProviderContainer(
      observers: [rebuilds],
      overrides: [
        // Every pane's buffer counts what reads it, so a switch that re-encodes
        // scrollback shows up in the unit `layout_save_cost_test` uses.
        ...fakeTerminalOverrides(
          database: db,
          instanceFactory: _countingFactory(terminals),
        ),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        hostCommandRunnerProvider.overrideWithValue(git),
        // Counted rather than run: the real one scans the CLI store, reads a
        // multi-megabyte JSONL and then polls it on a two-second timer, none of
        // which a widget test may do. What it costs is not in dispute; how
        // often a switch starts one is the measurement.
        sessionChatTranscriptProvider.overrideWith((ref, sessionId) {
          chatSubscriptions.add(sessionId);
          return Stream.value(const <TranscriptMessage>[]);
        }),
        // Real hosts and real timers, neither of which a widget test may have.
        // Deliberately **not** overridden: the delivery providers, the session
        // verdict and the review offer — those are the suspects, so they run.
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        sessionTranscriptProvider.overrideWith((ref, id) => Stream.value(const [])),
        importedTranscriptProvider.overrideWith(
          (ref, _) => Stream.value(const []),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  /// A bounded settle. `pumpAndSettle` never returns against the whole shell —
  /// something always has a frame scheduled — and the measurement only needs
  /// the work a switch queues to have drained, which a fixed run of frames
  /// does deterministically.
  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Adds [count] more idle rows to the same repository. Nothing about a
  /// switch is about them; they are there so a per-row cost shows up as a
  /// curve rather than as a constant.
  void seedIdleRows(int count) {
    for (var i = 0; i < count; i++) {
      SessionDao(db).insert(
        Session(
          id: 'idle$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Idle $i',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: testTime,
          externalSessionId: 'ext-idle$i',
        ),
      );
    }
  }

  /// Mounts the whole app and gives each session a live pane of its own, which
  /// is what "two active sessions" means.
  ///
  /// [deadPanes] idle rows additionally get a pane whose process has **exited**
  /// and whose screen holds output — the expensive shape, because a dead pane's
  /// card walks that screen looking for an agent's resume refusal. Opened
  /// before the tree is pumped, like the live ones: adding tabs to a mounted
  /// strip re-attaches its rail's scroll controller mid-frame, which is a
  /// separate complaint and not this file's subject.
  Future<void> mount(WidgetTester tester, {int deadPanes = 0}) async {
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
      SessionDao(db).updatePaneId(id, paneId);
    }
    for (var i = 0; i < deadPanes; i++) {
      controller.openTab(TerminalProfile.powerShell);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final instance = controller.instanceFor(paneId)! as FakeTerminalInstance;
      instance.terminal.write('a screenful of the run that ended\r\n' * 20);
      instance.livenessNotifier.value = PaneLiveness.exited;
      SessionDao(db).updatePaneId('idle$i', paneId);
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
    // per-row half of a switch's bill.
    await tester.tap(find.text('Demo'));
    await settle(tester);
    expect(
      find.byType(SessionCard),
      findsAtLeastNWidgets(3),
      reason: 'the rows whose cost is being measured have to be on screen',
    );
  }

  int encodes() => terminals.values.fold(0, (sum, t) => sum + t.bufferReads);

  int tailScans() => terminals.values.fold(0, (sum, t) => sum + t.tailReads);

  /// Opens both sessions once, so neither side of a measurement is the
  /// first-ever look at a session, and leaves `s1` up.
  Future<void> warmUp(WidgetTester tester) async {
    await container.read(explorerActionsProvider).openNative('s2');
    await settle(tester);
    await container.read(explorerActionsProvider).openNative('s1');
    await settle(tester);
  }

  void reset() {
    db.reset();
    rebuilds.reset();
    git.requests.clear();
    chatSubscriptions.clear();
  }

  void report(String label, int encodesBefore) {
    // ignore: avoid_print
    print(
      '$label statements=${db.count} reads=${db.reads.length} '
      'writes=${db.writes.length} rebuilds=${rebuilds.total} '
      'chatTranscripts=${chatSubscriptions.length}$chatSubscriptions '
      'processes=${git.requests.length} '
      'encodes=${encodes() - encodesBefore}',
    );
    // ignore: avoid_print
    print('$label-SQL ${_tally(db.statements)}');
    // ignore: avoid_print
    print('$label-PROVIDERS ${rebuilds.report}');
  }

  testWidgets('one Explorer switch spawns nothing and re-encodes nothing', (
    tester,
  ) async {
    await mount(tester);
    await warmUp(tester);
    reset();
    final before = encodes();

    await container.read(explorerActionsProvider).openNative('s2');
    await settle(tester);

    report('SWITCH-COST', before);
    expect(container.read(selectedSessionIdProvider), 's2');
    expect(
      git.requests,
      isEmpty,
      reason:
          'choosing which session to look at says nothing about any working '
          'tree, so it must start no process',
    );
    expect(
      encodes() - before,
      0,
      reason: 'no pane moved, so no scrollback may be re-encoded',
    );
  });

  testWidgets('a switch does not build the conversation behind the terminal', (
    tester,
  ) async {
    await mount(tester);
    await warmUp(tester);
    reset();

    await container.read(explorerActionsProvider).openNative('s2');
    await settle(tester);

    // The workbench lands on the terminal — always, by construction — so the
    // chat rendering of the session is not on screen and must not be built.
    expect(container.read(terminalVisibleProvider), isTrue);
    expect(
      find.byType(SessionTranscriptView),
      findsNothing,
      reason:
          'the conversation is not the surface the switch opened, and building '
          'it costs a CLI store scan and a whole-transcript parse for a view '
          'nobody is looking at',
    );
    expect(
      chatSubscriptions,
      isEmpty,
      reason:
          'each entry is one store scan plus one whole-file JSONL parse: '
          '$chatSubscriptions',
    );
  });

  testWidgets('the conversation is still one labelled tap away, and stays', (
    tester,
  ) async {
    // The guard against a false green: a cost test that passes because the
    // feature stopped working is worse than the cost it removed.
    await mount(tester);
    await warmUp(tester);

    await tester.tap(find.byTooltip('Chat view'));
    await settle(tester);

    expect(find.byType(SessionTranscriptView), findsOneWidget);
    expect(chatSubscriptions, contains('s1'));

    // ...and it survives the revision bumps the app publishes constantly.
    container.read(sessionsRevisionProvider.notifier).bump();
    await settle(tester);
    expect(find.byType(SessionTranscriptView), findsOneWidget);
  });

  testWidgets('switching away from the conversation lets it go', (tester) async {
    // The other half of the rule: a conversation that was asked for belongs to
    // the session it was asked for. Landing on another session's terminal must
    // not keep drawing — or re-reading — the one before it.
    await mount(tester);
    await warmUp(tester);
    await tester.tap(find.byTooltip('Chat view'));
    await settle(tester);
    reset();

    await container.read(explorerActionsProvider).openNative('s2');
    await settle(tester);

    expect(find.byType(SessionTranscriptView), findsNothing);
    expect(chatSubscriptions, isEmpty, reason: '$chatSubscriptions');
  });

  testWidgets('a switch wakes nothing belonging to an untouched session', (
    tester,
  ) async {
    // `s3` is neither the session left nor the session opened. Waking it is a
    // fan-out: the workbench used to publish its "the pane on screen moved"
    // change without naming a row, and a change that names no row is read —
    // correctly — as being about every row, so every per-session provider in
    // the app rebuilt on every switch. That is the cost the session-signal
    // work removed from a rename; a switch must not put it back.
    await mount(tester);
    await warmUp(tester);
    reset();

    await container.read(explorerActionsProvider).openNative('s2');
    await settle(tester);

    // ignore: avoid_print
    print('SWITCH-COST-UNTOUCHED ${rebuilds.forSession('s3')}');
    expect(
      rebuilds.forSession('s3'),
      isEmpty,
      reason: 'a session the switch never named must stay asleep',
    );
  });

  group('a switch costs the same however large the workspace is', () {
    /// Filled by the cases below so the shape can be asserted across them.
    final statements = <int, int>{};
    final cards = <int, int>{};

    // Past the viewport on purpose. The Explorer builds only the cards a
    // screenful holds (`explorer_panel_scale_test`), so beyond that point the
    // *whole* switch has to stop noticing rows exist — which is the property
    // the session-signal work bought and this guards.
    for (final extra in [20, 100, 400]) {
      testWidgets('with $extra rows in the tree', (tester) async {
        seedIdleRows(extra);
        await mount(tester);
        cards[extra] = tester.widgetList(find.byType(SessionCard)).length;
        await warmUp(tester);
        reset();

        await container.read(explorerActionsProvider).openNative('s2');
        await settle(tester);

        statements[extra] = db.count;
        // ignore: avoid_print
        print(
          'SWITCH-SCALE rows=$extra cardsDrawn=${cards[extra]} '
          'statements=${db.count} rebuilds=${rebuilds.total}',
        );
      });
    }

    test('so the curve is flat past the viewport', () {
      expect(statements.keys, containsAll([20, 100, 400]));
      expect(
        cards.values.toSet(),
        hasLength(1),
        reason: 'the viewport must already be full at the smallest size: $cards',
      );
      expect(
        statements.values.toSet(),
        hasLength(1),
        reason: 'a switch is about two rows, not about the workspace: '
            '$statements',
      );
    });
  });

  testWidgets('a switch reads no dead pane\'s screen', (tester) async {
    // `sessionWhereaboutsProvider` scans a dead pane's buffer for an agent's
    // resume refusal, and `SessionWhereabouts` carries no `==`, so every
    // recompute counts as a change downstream. A switch that woke those cards
    // would pay a screen walk per drawn dead pane, on the UI isolate. It does
    // not wake them — the switch names the row it moved — so the walk never
    // happens and the missing equality costs this path nothing.
    seedIdleRows(6);
    await mount(tester, deadPanes: 6);
    await warmUp(tester);
    reset();
    final before = tailScans();

    await container.read(explorerActionsProvider).openNative('s2');
    await settle(tester);

    // ignore: avoid_print
    print('SWITCH-COST-TAILS tailScans=${tailScans() - before}');
    // ignore: avoid_print
    print('SWITCH-COST-TAILS-PROVIDERS ${rebuilds.report}');
    expect(
      tailScans() - before,
      0,
      reason: 'a switch says nothing about a pane that died before it',
    );

    // The guard against a false green: the scan is still there to be paid, and
    // a signal that genuinely names every row still pays it. Without this the
    // assertion above would pass just as well if the cards had stopped
    // describing dead panes at all.
    final beforeBump = tailScans();
    container.read(sessionsRevisionProvider.notifier).bump();
    await settle(tester);
    // ignore: avoid_print
    print('SWITCH-COST-TAILS onCoarseBump=${tailScans() - beforeBump}');
    expect(
      tailScans() - beforeBump,
      greaterThan(0),
      reason: 'a change that names no row must still reach every dead card',
    );
  });

  testWidgets('one workbench tab switch spawns nothing', (tester) async {
    await mount(tester);
    await container.read(explorerActionsProvider).openNative('s1');
    await settle(tester);

    final tabs = container.read(terminalSessionsControllerProvider).tabs;
    reset();
    final before = encodes();

    container
        .read(terminalSessionsControllerProvider.notifier)
        .activateTab(tabs.last.id);
    await settle(tester);

    report('TAB-SWITCH-COST', before);
    expect(git.requests, isEmpty);
    expect(encodes() - before, 0);
    expect(chatSubscriptions, isEmpty, reason: '$chatSubscriptions');
  });
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

  /// Everything rebuilt *for* one session, by name. A family provider carries
  /// its argument in the label, so this is the whole per-row bill for a row.
  Map<String, int> forSession(String sessionId) => {
    for (final entry in counts.entries)
      if (entry.key.endsWith('($sessionId)')) entry.key: entry.value,
  };
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

/// A pane factory whose terminals count reads of their buffer.
/// A [CountingTerminal] that also counts **screen scans** — reads of the active
/// buffer made by `terminalTailLines`, and not xterm's own reads while it
/// writes or paints.
///
/// A dead pane's Explorer card scans that pane's screen every time
/// `sessionWhereaboutsProvider` recomputes, looking for an agent's resume
/// refusal, and `SessionWhereabouts` carries no `==` so every recompute counts
/// as a change downstream. The walk is on the UI isolate, so anything that
/// wakes those cards pays one per drawn dead pane. This is what prices it.
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
