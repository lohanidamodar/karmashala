import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **What a project costs per recorded checkout**, at the size the owner's
/// workspace actually reached.
///
/// The report that prompted this: a `project_rescan` took one project from
/// **1** recorded checkout to **69** — a hub, a dozen sibling clones and ~25
/// `wt-*` worktrees — and the app began to hang. Every one of those 69 is a WSL
/// path reached from Windows over `\\wsl.localhost`, where a single stat costs
/// 1.19 ms against 0.07 ms for a local path, so a git process there is not a
/// rounding error. Correlation is not cause, so this file measures instead of
/// assuming.
///
/// Counted, not timed, for the reason `test/features/terminal/scale_curve_test.dart`
/// gives: absolute milliseconds on a shared machine are noise, and a count is
/// the deterministic half of the shape. Three points — 1, 10 and 69 — so a
/// regression reads as a slope. The unit is the **git subprocess**, because
/// that is what crossing the 9p boundary charges for.
///
/// **What it found, before the fix** (git subprocesses, by number of recorded
/// checkouts):
///
/// | checkouts | collapsed | expanded | rows drawn | per workspace mutation |
/// |---|---|---|---|---|
/// | 1  | 5   | 6   | 1  | 6   |
/// | 10 | 50  | 60  | 10 | 60  |
/// | 69 | 345 | 414 | 13 | 414 |
///
/// Exactly linear: **six git processes per recorded checkout**, 414 of them to
/// draw thirteen visible rows, and the whole 414 again on every workspace
/// mutation — a session starting, stopping or changing status. 345 of them ran
/// with the project *collapsed*, drawing nothing at all. Two causes, both now
/// fixed: `projectSummaryProvider` used `ref.watch` on an `autoDispose` family,
/// which **creates** rather than reads, and the tree ran one `git worktree
/// list` per repository row.
///
/// The invariant the assertions encode, and the rule the design note/// already holds the terminal to: work must be proportional to what is
/// **visible**, not to what is recorded. Since the Explorer now lists sessions
/// and not checkouts, that invariant is **flatness in the checkout count** —
/// the same cost at 69 checkouts as at 1, not merely a smaller slope.
///
/// ## Two more properties, added for the start-up report
///
/// Flatness says how *many* processes a scene costs. It says nothing about
/// **when** they run or **how many at a time**, and the owner's 1.13.0+26
/// report — *"startup is the most laggy and it's taking a lot of memory and
/// cpu"* — was about both. A 60 s profile of that build named
/// `RtlCreateUnicodeString` (4.60%, the largest single leaf) and
/// `NtCreateUserProcess` (2.02%) among the top Dart CPU leaves with
/// `_Utf8Decoder.decode16` and `_StringBase._interpolate` under them: spawning
/// git and reading its output, charged to the isolate that asked. It is charged
/// there because `Process.run` only looks asynchronous — `CreateProcessW` runs
/// on the calling thread before the future exists — and
/// `checkoutDeliveryProvider` was reached from a widget's `build`, so a window
/// opening onto thirteen rows paid for every one of those spawns inside one
/// frame's build phase.
///
/// **Honestly: the burst itself was not captured.** It had rolled off the VM
/// timeline's ring buffer before a snapshot could be taken, and six samples
/// over 12 s of idle found zero git processes — so `autoDispose` is working and
/// this is a start-up and expand burst, not ongoing churn. The code path, the
/// CPU leaves and the report agree; that agreement is the evidence, and it is
/// weaker than a measurement of the burst would have been.
///
/// So two properties join flatness, and both are counted rather than timed for
/// the same reason:
///
/// * **Nothing spawns inside a frame.** Every subprocess is stamped with the
///   scheduler phase it started in, and the only phase allowed is
///   [SchedulerPhase.idle]. A spawn in [SchedulerPhase.persistentCallbacks] is
///   one the user paid for in the frame they were waiting on.
/// * **How many run at once**, measured as a peak of overlapping subprocesses
///   — which needs a fake that yields, since one that answers instantly can
///   never overlap with anything and would report a peak of one however wide
///   the fan-out. Measured at **2 / 20 / 28** with nothing bounding it;
///   [kCheckoutProbeConcurrency] is the bound, and the peak is asserted
///   against it where the fan-out is widest.
void main() {
  /// The three points the curve is read at. One checkout is the "did we make
  /// the ordinary project worse" control; 69 is the owner's real number.
  const scale = [1, 10, 69];

  late AppDatabase db;
  late _ProbeRunner git;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    AgentInstallationDao(db).insert(agentInstallation());
    git = _ProbeRunner(responder: _git);
  });
  tearDown(() => db.close());

  /// [count] checkouts in one project: the hub itself, then sibling clones
  /// beside it — the shape a rescan of a workspace hub records. Each is an
  /// independent repository, which is the conservative case: folding worktrees
  /// under an owner removes *rows*, never the git that discovered them.
  ///
  /// One session on the hub, so the tree has something to place and the
  /// measurement is of checkouts rather than of an empty project.
  void seed(int count) {
    RepositoryDao(
      db,
    ).insert(repository(id: 'r0', name: 'hub', path: r'C:\hub'));
    for (var i = 1; i < count; i++) {
      RepositoryDao(db).insert(
        repository(
          id: 'r$i',
          name: 'clone$i',
          path:
              r'C:\hub\clone'
              '$i',
        ),
      );
    }
    SessionDao(db).insert(
      Session(
        id: 'n0',
        repositoryId: 'r0',
        agentInstallationId: 'a1',
        title: 'Native 0',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: 'native-ext-0',
      ),
    );
  }

  /// The same [count] checkouts, with **a session in each** so the tree draws
  /// as many rows as it has room for.
  ///
  /// [seed] draws one row at every scale, which is what makes it the right
  /// instrument for flatness — but one row's five processes can never overlap
  /// more than twice, so a concurrency bound measured on it would pass however
  /// large it was. A scene has to be able to *exceed* the bound before the
  /// bound means anything, and thirteen rows on thirteen distinct checkouts
  /// can: distinct, because Riverpod folds two rows in one working tree into
  /// one probe and rightly so.
  void seedOnePerCheckout(int count) {
    seed(count);
    for (var i = 1; i < count; i++) {
      SessionDao(db).insert(
        Session(
          id: 'n$i',
          repositoryId: 'r$i',
          agentInstallationId: 'a1',
          title: 'Native $i',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: 'native-ext-$i',
        ),
      );
    }
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required bool expand,
  }) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        // **The real gate**, not the neutralised one the rest of the suite
        // uses: this is the file that measures when a probe is allowed to
        // spawn, so it has to be the frame the app really waits for.
        ...fakeTerminalOverrides(database: db, frameGatedProbes: true),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    if (expand) {
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();
    }
    return container;
  }

  /// Git subprocesses so far, split by subcommand — the breakdown says *which*
  /// fan-out is the expensive one, which a single total cannot.
  Map<String, int> gitCounts() {
    final counts = <String, int>{};
    for (final request in git.requests) {
      // Every call is `git -C <dir> …`; the subcommand is what identifies it.
      final args = request.arguments.skip(2).toList();
      if (args.isEmpty) continue;
      final key =
          args.length > 1 &&
              (args.first == 'worktree' ||
                  args.first == 'remote' ||
                  args.first == 'rev-list' ||
                  args.first == 'rev-parse')
          ? '${args[0]} ${args[1]}'
          : args.first;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  int totalGit() => git.requests.length;

  group('a collapsed project', () {
    // Filled by the cases below so the *shape* can be asserted across them
    // rather than inside any one of them.
    final gitByScale = <int, int>{};

    for (final count in scale) {
      testWidgets('$count checkouts', (tester) async {
        seed(count);
        await pump(tester, expand: false);
        final rows = tester.widgetList(find.byType(SessionCard)).length;
        gitByScale[count] = totalGit();
        // ignore: avoid_print
        print(
          'CHECKOUT-COST collapsed checkouts=$count '
          'git=${totalGit()} rows=$rows detail=${gitCounts()}',
        );
        // Nothing is expanded, so nothing is drawn — and nothing recorded may
        // be paid for.
        expect(rows, 0, reason: 'a collapsed project draws no session cards');
      });
    }

    testWidgets('costs no git per recorded checkout', (tester) async {
      // The three cases above ran first and filled the map.
      expect(gitByScale.keys.toSet(), scale.toSet());
      // ignore: avoid_print
      print('CHECKOUT-COST collapsed curve=$gitByScale');
      // The invariant: a header the user has not opened draws nothing, so it
      // must ask git nothing — at any number of recorded checkouts.
      expect(
        gitByScale.values.toSet(),
        {0},
        reason:
            'a collapsed project ran git ($gitByScale) — work proportional to '
            'what is recorded rather than to what is visible',
      );
    });
  });

  group('an expanded project', () {
    final gitByScale = <int, int>{};
    final rowsByScale = <int, int>{};

    for (final count in scale) {
      testWidgets('$count checkouts', (tester) async {
        seed(count);
        await pump(tester, expand: true);
        final rows = tester.widgetList(find.byType(SessionCard)).length;
        gitByScale[count] = totalGit();
        rowsByScale[count] = rows;
        // ignore: avoid_print
        print(
          'CHECKOUT-COST expanded checkouts=$count '
          'git=${totalGit()} rows=$rows peak=${git.peakInFlight} '
          'phases=${git.phaseNames} detail=${gitCounts()}',
        );
        // Non-vacuity for the phase claim below: a scene that asked git
        // nothing would satisfy it trivially.
        expect(totalGit(), greaterThan(0));
        expect(
          git.phases,
          {SchedulerPhase.idle},
          reason:
              'a git subprocess started inside a frame (${git.phaseNames}) — '
              '`CreateProcessW` runs on the calling thread, so that is time '
              'charged to the frame the user was waiting on',
        );
      });
    }

    testWidgets('costs git per visible row, not per checkout', (tester) async {
      expect(gitByScale.keys.toSet(), scale.toSet());
      // ignore: avoid_print
      print('CHECKOUT-COST expanded curve=$gitByScale rows=$rowsByScale');
      // The project holds one session at every scale, so it draws one card at
      // every scale: rows follow sessions, not the repositories table.
      expect(rowsByScale.values.toSet(), {
        1,
      }, reason: 'the panel drew a row per recorded checkout ($rowsByScale)');
      // Git is charged for the session card that is actually on screen — the
      // same handful of processes whether the project has 1 checkout or 69.
      expect(
        gitByScale.values.toSet(),
        {gitByScale[1]},
        reason:
            'expanding a project cost $gitByScale git processes — a fan-out '
            'proportional to what is recorded rather than to what is drawn',
      );
    });
  });

  group('one workspace mutation', () {
    final gitByScale = <int, int>{};

    for (final count in scale) {
      testWidgets('$count checkouts', (tester) async {
        seed(count);
        final container = await pump(tester, expand: true);
        // Warm: everything the first frame wanted has been asked for.
        final before = totalGit();
        container.read(sessionsRevisionProvider.notifier).bump();

        // **The bump arrives from outside a frame** — a session starting or
        // stopping, not a widget building — and the probes still wait for one.
        // Draining microtasks without pumping is what tells a frame apart from
        // a bare `await`: a gate that only yielded a microtask would have
        // spawned by now, and would delay the frame that shows the new state
        // instead of following it.
        await tester.idle();
        expect(
          totalGit(),
          before,
          reason:
              'a workspace mutation spawned git before the next frame was '
              'drawn',
        );

        await tester.pumpAndSettle();
        gitByScale[count] = totalGit() - before;
        expect(gitByScale[count], greaterThan(0), reason: 'the re-read ran');
        // ignore: avoid_print
        print(
          'CHECKOUT-COST mutation checkouts=$count '
          'git=${gitByScale[count]}',
        );
      });
    }

    testWidgets('re-reads only what is on screen', (tester) async {
      expect(gitByScale.keys.toSet(), scale.toSet());
      // ignore: avoid_print
      print('CHECKOUT-COST mutation curve=$gitByScale');
      // A session starting or ending bumps this revision, so it happens
      // constantly. If it costs a git pass over every recorded checkout,
      // ordinary use of the app is a subprocess storm — which is exactly what
      // the owner reported as a freeze.
      expect(
        gitByScale.values.toSet(),
        {gitByScale[1]},
        reason:
            'one workspace mutation cost $gitByScale git processes — '
            'proportional to what is recorded',
      );
    });
  });

  /// **When** a full screen of rows spawns, and **how many at a time.**
  ///
  /// A session in every checkout, so the pane draws as many rows as it fits and
  /// the fan-out is wide enough for a bound to matter. Flatness is not asserted
  /// here — this scene *does* grow with the checkout count, because every
  /// checkout has a row wanting to be drawn — the groups above own that.
  group('a full pane of rows', () {
    final gitByScale = <int, int>{};
    final rowsByScale = <int, int>{};
    final peakByScale = <int, int>{};

    for (final count in scale) {
      testWidgets('$count checkouts, one session each', (tester) async {
        seedOnePerCheckout(count);
        await pump(tester, expand: true);
        final rows = tester.widgetList(find.byType(SessionCard)).length;
        gitByScale[count] = totalGit();
        rowsByScale[count] = rows;
        peakByScale[count] = git.peakInFlight;
        // ignore: avoid_print
        print(
          'CHECKOUT-COST rows checkouts=$count '
          'git=${totalGit()} rows=$rows peak=${git.peakInFlight} '
          'phases=${git.phaseNames} detail=${gitCounts()}',
        );

        // Nothing spawns inside a frame — the property the start-up report is
        // about, asserted where the fan-out is widest.
        expect(totalGit(), greaterThan(0));
        expect(
          git.phases,
          {SchedulerPhase.idle},
          reason:
              'a git subprocess started inside a frame (${git.phaseNames}) '
              'while $rows rows were being drawn',
        );
        // And no more than a paneful at a time. Measured at 2 / 20 / 28 with
        // nothing bounding it: twenty-eight `\\wsl.localhost` round trips
        // alive together to fill in ten branch chips.
        expect(
          git.peakInFlight,
          lessThanOrEqualTo(kCheckoutProbeConcurrency),
          reason:
              '${git.peakInFlight} git subprocesses were alive together while '
              '$rows rows were being drawn, over the '
              '$kCheckoutProbeConcurrency `CheckoutProbeQueue` allows',
        );
      });
    }

    testWidgets('draws a pane full of rows', (tester) async {
      expect(gitByScale.keys.toSet(), scale.toSet());
      // ignore: avoid_print
      print(
        'CHECKOUT-COST rows curve=$gitByScale rows=$rowsByScale '
        'peak=$peakByScale',
      );
      // Non-vacuity: the whole point of this group is a scene wide enough for
      // *when* and *how many* to be visible at all.
      expect(
        rowsByScale[69],
        greaterThan(1),
        reason: 'the pane drew ${rowsByScale[69]} rows at 69 checkouts',
      );
      expect(peakByScale.values, everyElement(greaterThan(0)));
      // **The peak stops growing**, which is what a bound is for and what the
      // per-scale assertions cannot say between them: 2 / 20 / 28 was a peak
      // that followed the fan-out, and a bound is a peak that follows nothing.
      expect(
        peakByScale.values,
        everyElement(lessThanOrEqualTo(kCheckoutProbeConcurrency)),
        reason:
            'the peak in flight was $peakByScale — a fan-out released into '
            'one microtask queue rather than one bounded at '
            '$kCheckoutProbeConcurrency',
      );
    });
  });

  /// **What a repository with several worktrees pays**, which is a different
  /// property from anything above and is not implied by any of them.
  ///
  /// Flatness is flatness *in the checkout count*: the groups above seed
  /// independent repositories, deliberately, because that is the conservative
  /// case for the question they ask. It means they cannot see sharing at all —
  /// with one clone per checkout there is nothing to share, so a per-checkout
  /// question and a per-repository one cost exactly the same and every
  /// assertion above passes either way.
  ///
  /// The owner's workspace is the opposite shape: one hub clone with ~25
  /// `wt-*` worktrees beside it. `origin`'s URL and `origin/HEAD` are
  /// properties of the **repository** — they live in `.git/config` and
  /// `refs/remotes/origin/HEAD`, and a worktree's `.git` is a file pointing at
  /// the clone's git directory — so all twenty-six rows have the same two
  /// answers, and until Loop 74 all twenty-six asked for them.
  ///
  /// Measured directly rather than through the pane, and with a fake that
  /// answers without yielding: this group is about *how many* questions are
  /// asked, so the frame gate and the concurrency bound — which are about
  /// *when* and *how many at a time* — would only add pumping to it. The
  /// groups above own both of those.
  group('worktrees of one repository', () {
    const repoPath = EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\hub',
    );
    const worktrees = 5;

    EnvironmentPath worktreeAt(int i) => EnvironmentPath(
      environmentId: 'windows',
      path:
          r'C:\hub\.karmashala-worktrees\wt-'
          '$i',
    );

    /// One clone, [worktrees] worktrees of it, and a session in each — the
    /// shape a fan-out over one repository leaves behind.
    void seedWorktrees() {
      RepositoryDao(db).insert(repository(id: 'r0', name: 'hub', path: r'C:\hub'));
      for (var i = 0; i < worktrees; i++) {
        SessionDao(db).insert(
          Session(
            id: 'w$i',
            repositoryId: 'r0',
            agentInstallationId: 'a1',
            title: 'Worktree $i',
            useWorktree: true,
            worktree: worktreeAt(i),
            status: SessionStatus.running,
            createdAt: testTime,
            externalSessionId: 'wt-ext-$i',
          ),
        );
      }
    }

    testWidgets('ask origin once, not once per worktree', (tester) async {
      seedWorktrees();
      // A plain fake: instant answers, so nothing here needs a frame pumped.
      final flat = FakeCommandRunner(responder: _git);
      final container = ProviderContainer(
        overrides: [
          // The neutral gate the rest of the suite takes — see
          // `headlessProbeGate`. This container has no widget tree.
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: flat),
          ),
        ],
      );
      addTearDown(container.dispose);

      // `listen` and not a bare `read`: an `autoDispose` family with no
      // listener is collected the moment it is created, and the whole property
      // under test is that the second worktree finds the first one's answer
      // still there.
      final readings = <Future<void>>[];
      for (var i = 0; i < worktrees; i++) {
        final provider = worktreeDeliveryProvider((
          repo: repoPath,
          worktree: worktreeAt(i),
        ));
        final subscription = container.listen(provider, (_, _) {});
        addTearDown(subscription.close);
        readings.add(container.read(provider.future));
      }
      await Future.wait(readings);

      final counts = <String, int>{};
      for (final request in flat.requests) {
        final args = request.arguments.skip(2).toList();
        if (args.isEmpty) continue;
        final key = args.length > 1 && args.first != 'status'
            ? '${args[0]} ${args[1]}'
            : args.first;
        counts[key] = (counts[key] ?? 0) + 1;
      }
      // ignore: avoid_print
      print(
        'CHECKOUT-COST worktrees repos=1 worktrees=$worktrees '
        'git=${flat.requests.length} detail=$counts',
      );

      // Non-vacuity, and the control: the working-tree question really is
      // asked once per working tree — five worktrees plus the clone they came
      // from — so a repository question asked once is sharing rather than a
      // scene that asked nothing.
      expect(
        counts['status'],
        worktrees + 1,
        reason:
            'the scene has ${worktrees + 1} working trees; '
            '`git status` ran ${counts['status']} times',
      );
      expect(
        counts['remote get-url'],
        1,
        reason:
            '`git remote get-url origin` ran ${counts['remote get-url']} times '
            'for one repository — a repository question asked once per '
            'worktree',
      );
      expect(
        counts['rev-parse --abbrev-ref'],
        1,
        reason:
            '`git rev-parse --abbrev-ref origin/HEAD` ran '
            '${counts['rev-parse --abbrev-ref']} times for one repository — a '
            'repository question asked once per worktree',
      );
    });
  });
}

/// The fake git, plus the two things this file now has to know about a
/// subprocess besides that it happened: **when** it started and **how many
/// others were running**.
///
/// The scheduler phase is the honest way to ask "was this inside a frame".
/// `Process.run` is not asynchronous the way it reads — `CreateProcessW` runs
/// on the calling thread before the future exists — so a spawn recorded in
/// [SchedulerPhase.persistentCallbacks] is one the user paid for in the frame
/// they were waiting on, and a spawn recorded at [SchedulerPhase.idle] is one
/// the window has already painted around.
class _ProbeRunner extends FakeCommandRunner {
  _ProbeRunner({super.responder});

  /// Every scheduler phase a subprocess has been started in.
  final Set<SchedulerPhase> phases = {};

  int _inFlight = 0;

  /// The most subprocesses that were ever running together.
  int peakInFlight = 0;

  String get phaseNames => phases.map((p) => p.name).toList().toString();

  @override
  Future<CommandResult> run(CommandRequest request) async {
    // Stamped and recorded *before* the yield, because that is when a real
    // process would already exist.
    phases.add(SchedulerBinding.instance.schedulerPhase);
    final result = super.run(request);
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    try {
      // One yield, and it is what makes the peak measurable: a fake that
      // answers without ever giving up the isolate can never overlap with
      // anything, so an unbounded fan-out would still report a peak of one.
      //
      // **A frame and not a `Future.delayed`,** which was tried first and
      // silently truncated the measurement. `pumpAndSettle` stops as soon as a
      // pump leaves no *frame* scheduled, and a probe parked on a bare timer
      // leaves none — so the settle returned with one process counted, four
      // never started, and a pending timer the binding rightly complained
      // about. A frame is also the truer stand-in: a real git process outlives
      // several.
      await SchedulerBinding.instance.endOfFrame;
      return await result;
    } finally {
      _inFlight--;
    }
  }
}

/// Enough of a real git for every provider on the path to complete rather than
/// fold into "nothing to say" — an erroring fake would measure the error path.
CommandResult _git(CommandRequest request) {
  // Every call arrives as `git -C <dir> …`; the subcommand starts at index 2.
  final joined = request.arguments.skip(2).join(' ');
  if (joined.startsWith('worktree list')) {
    // The directory is the `-C` argument, not `workingDirectory`, which
    // `GitService` never sets.
    final path = request.arguments[1];
    return CommandResult(
      exitCode: 0,
      stdout:
          'worktree ${path.replaceAll(r'\', '/')}\nbranch refs/heads/main\n',
      stderr: '',
    );
  }
  if (joined.startsWith('status')) {
    return const CommandResult(
      exitCode: 0,
      stdout: '## main...origin/main\n M lib/a.dart\n',
      stderr: '',
    );
  }
  if (joined.startsWith('remote get-url')) {
    return const CommandResult(
      exitCode: 0,
      stdout: 'https://github.com/acme/hub.git\n',
      stderr: '',
    );
  }
  if (joined.startsWith('rev-parse --abbrev-ref origin/HEAD')) {
    return const CommandResult(
      exitCode: 0,
      stdout: 'origin/main\n',
      stderr: '',
    );
  }
  if (joined.startsWith('rev-list --left-right')) {
    return const CommandResult(exitCode: 0, stdout: '0\t2\n', stderr: '');
  }
  if (joined.startsWith('diff --numstat')) {
    return const CommandResult(
      exitCode: 0,
      stdout: '10\t2\tlib/a.dart\n',
      stderr: '',
    );
  }
  return const CommandResult(exitCode: 0, stdout: '', stderr: '');
}
