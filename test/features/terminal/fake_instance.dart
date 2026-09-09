import 'dart:convert';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_refresh_policy.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/cast_recorder.dart';
import 'package:karmashala/src/features/terminal/data/cold_screen.dart';
import 'package:karmashala/src/features/terminal/data/command_block_recorder.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_park.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_spool.dart';
import 'package:karmashala/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/detach_policy.dart';
import 'package:karmashala/src/features/terminal/domain/ingest_tier.dart';
import 'package:karmashala/src/features/terminal/domain/osc_router.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';
import 'package:karmashala/src/features/terminal/application/terminal_profiles.dart';

import '../../support/fakes.dart';
import '../agents/usage_fixtures.dart';

/// A process-free [TerminalInstance] so the controller can be tested without
/// spawning a real PTY.
class FakeTerminalInstance
    implements
        TerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance,
        RecordableTerminalInstance {
  FakeTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    String? workingDirectory,
    this.restored,
    this.agentLaunch,
    Terminal? adoptTerminal,
    bool shellIntegration = false,
  }) : adopted = adoptTerminal,
       _cwd = WorkingDirectoryTracker(workingDirectory) {
    terminal = adoptTerminal ?? (Terminal(maxLines: 1000)..resize(40, 10));
    // Wired exactly as a real pane wires it: the pane owns xterm's single OSC
    // slot and fans it out, so a test can write OSC 7 and OSC 133 at the same
    // buffer and have both land.
    terminal.onPrivateOSC = _osc.dispatch;
    // ...including the second door OSC 7 now comes through: xterm2 consumes it
    // rather than reporting it as an unknown OSC.
    terminal.onCurrentDirectoryChange = (uri) => _osc.dispatch('7', [uri]);
    _osc.add(_cwd.handleOsc);
    // Attached on the same condition a real pane attaches it, so a test can
    // exercise OSC 133 — command blocks, and `terminal_run` waiting on one —
    // by writing the markers a shell would emit.
    if (shellIntegration) {
      commandBlocks = CommandBlockRecorder(terminal)..attach(_osc);
    }
    if (adoptTerminal == null && restored != null && restored!.isNotEmpty) {
      terminal.write(restored!);
    }
  }

  /// The buffer this pane was handed instead of text, if it was — asserted on
  /// by the resume-cost gate.
  final Terminal? adopted;

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;

  /// The launch directory until a test writes an OSC 7, exactly as a real
  /// pane's is.
  final WorkingDirectoryTracker _cwd;
  final OscRouter _osc = OscRouter();

  @override
  String? get workingDirectory => _cwd.value;

  @override
  ValueListenable<String?> get directory => _cwd.listenable;

  @override
  final AgentPaneLaunch? agentLaunch;

  /// What the factory was handed to replay — asserted on by the restore tests.
  final String? restored;

  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  /// Null unless the pane was built with shell integration, exactly as a real
  /// one is: the UI has to tell "no integration" from "integrated, nothing run
  /// yet".
  @override
  CommandBlockRecorder? commandBlocks;

  /// Live until disposed, so the fake exercises the same detach/end paths a
  /// real PTY does.
  @override
  ValueListenable<PaneLiveness> get liveness => livenessNotifier;
  final livenessNotifier = ValueNotifier(PaneLiveness.live);

  /// What the process exited with, for the collapse-on-exit rule. Null — "we
  /// never learned" — unless a test says otherwise, which is the safe default.
  @override
  int? exitCode;

  /// What the shell had on screen before the user ran anything — settable so a
  /// test can give a pane the multi-line prompt a real one has.
  @override
  int? greetingLines;

  /// Ends this pane the way a shell that was typed `exit` at ends: cleanly.
  void exitCleanly() => exitWith(0);

  /// Ends the process with [code].
  ///
  /// Reach for `exitWith(1)` — not [exitCleanly] — whenever a test just needs a
  /// pane that is **no longer running**, which is most of them. A *clean* exit
  /// means the user typed `exit`, and `shouldCollapseOnExit` answers that by
  /// closing the pane and its tab; a test that wanted a dead pane to still be
  /// there would find nothing left to assert on. A non-zero exit is evidence
  /// somebody may still be reading, so it stays exactly where it was.
  void exitWith(int code) {
    exitCode = code;
    livenessNotifier.value = PaneLiveness.exited;
  }

  bool disposed = false;

  /// What the controller last told this pane about how visible it is, and every
  /// value it has been told — a fake pane has no pipe, so the tier is the only
  /// observable part of *ingestion* at this level.
  @override
  IngestTier ingestTier = IngestTier.hot;
  final tierHistory = <IngestTier>[];

  /// Storage, though, is real: the fake parks, spools and refreshes its screen
  /// through the same [ColdIngest] a PTY pane does — the same detach, the same
  /// reattach — so the tiering is exercised by every controller test and by the
  /// scale benchmark rather than only by a pane nothing can construct without
  /// spawning a shell.
  ///
  /// Its own budget, and no throttle: a fake pane's output arrives one `receive`
  /// at a time because a test said so, so rationing it would only make tests
  /// wait. What the interval and the shared pool actually do is pinned by
  /// `cold_screen_test.dart`.
  late final ColdIngest cold = ColdIngest(
    terminal: terminal,
    budget: TerminalIngestBudget(),
    refreshInterval: Duration.zero,
  );

  ScrollbackPark get park => cold.park;
  ScrollbackSpool get spool => cold.spool;
  ColdScreen get coldScreen => cold.screen;

  @override
  String? get parkedScrollback => cold.parkedScrollback;

  /// The same rule [PtyTerminalInstance] applies: a pane that has stopped and
  /// still has its buffer can hand it over; a parked one cannot, because it
  /// gave its buffer up.
  @override
  Terminal? get adoptableBuffer =>
      !livenessNotifier.value.isLive && !park.isParked ? terminal : null;

  CastRecorder? _recorder;

  @override
  CastRecorder? get recorder => _recorder;

  @override
  void startRecording(CastRecorder recorder) => _recorder = recorder;

  @override
  void stopRecording() => _recorder = null;

  /// Output arriving from the process this pane does not have, through the same
  /// tiering a real pane's bytes go through — and past the same recording tap,
  /// which is upstream of the tier for the reason
  /// [RecordableTerminalInstance] gives.
  void receive(String text) {
    final bytes = const Utf8Encoder().convert(text);
    _recorder?.addOutput(bytes);
    if (ingestTier == IngestTier.cold) {
      cold.add(bytes);
      return;
    }
    terminal.write(text);
  }

  /// A resize a test performs on the pane, forwarded the way a real pane
  /// forwards one.
  void resizeGrid(int columns, int rows) {
    _recorder?.addResize(columns, rows);
    terminal.resize(columns, rows);
  }

  @override
  void setIngestTier(IngestTier tier) {
    if (ingestTier == tier) return;
    final wasCold = ingestTier == IngestTier.cold;
    ingestTier = tier;
    tierHistory.add(tier);
    if (tier == IngestTier.cold) {
      cold.detach(Uint8List(0));
    } else if (wasCold) {
      cold.reattach();
    }
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    _recorder?.sourceEnded();
    _recorder = null;
    livenessNotifier.value = PaneLiveness.exited;
    livenessNotifier.dispose();
    _cwd.dispose();
    focusNode.dispose();
    scrollController.dispose();
  }
}

/// Divides the active tab and starts a terminal in the new region — the old
/// one-call `splitPane`.
///
/// Splitting itself no longer launches anything (see
/// [TerminalSessionsController.splitPane]): it clears room, and something else
/// fills it. A test that wants two *live* panes therefore has to ask for both
/// halves, and this says so once rather than in thirty places.
extension SplitWithTerminal on TerminalSessionsController {
  String? splitPaneWith(
    SplitAxis axis,
    TerminalProfile profile, {
    String? workingDirectory,
  }) {
    final slot = splitPane(axis);
    if (slot == null) return null;
    return openInSlot(slot, profile, workingDirectory: workingDirectory);
  }
}

/// Makes a fake pane look like a shell somebody has actually used.
///
/// Closing a pane no longer always detaches it: `shouldDetachOnClose` releases
/// an *idle* plain shell rather than leaving a PowerShell running with no tab.
/// A fake pane's buffer starts empty, which is exactly the "opened it, typed
/// nothing" case that policy releases — so a test about detaching, reattaching
/// or background sessions has to be about a pane worth detaching, and says so
/// by calling this.
void giveShellHistory(TerminalInstance instance) {
  for (var i = 0; i <= kIdleShellHistoryLines; i++) {
    instance.terminal.write('history line $i\r\n');
  }
}

/// A container whose terminals are fakes, optionally over a real in-memory
/// database so persistence can be exercised.
ProviderContainer fakeTerminalContainer({
  AppDatabase? database,
  bool restoreLivePanes = true,
}) => ProviderContainer(
  overrides: fakeTerminalOverrides(
    database: database,
    restoreLivePanes: restoreLivePanes,
  ),
);

/// The overrides behind [fakeTerminalContainer], so a test that needs more of
/// them can spread this list rather than reproduce a second, friendlier fake.
///
/// The return type is inferred on purpose: Riverpod's `Override` is a sealed
/// type its public library does not export, so it cannot be written down here.
// ignore: strict_top_level_inference
fakeTerminalOverrides({
  AppDatabase? database,
  TerminalInstanceFactory? instanceFactory,
  AgentUsageService? usageService,
  bool shellIntegration = false,
  bool restoreLivePanes = true,
  Duration usagePollFloor = Duration.zero,
  bool frameGatedProbes = false,
  GitFiles? gitFiles,
}) {
  return [
    // Off by default for the same reason and in the same words as
    // `deliveryPollIntervalProvider` below — see [headlessProbeGate]. The one
    // test that is *about* the gate asks for the real one.
    if (!frameGatedProbes)
      probeGateProvider.overrideWithValue(headlessProbeGate),
    // No disk by default, and a test that is *about* the two files a delivery
    // reading reads hands its own in here rather than adding a second override
    // — Riverpod refuses the same provider twice in one container, the same
    // constraint `agentUsageServiceProvider` below is written to. See
    // [NoGitFiles] for why real file I/O in a fake-async test is not a
    // tidiness question.
    gitFilesProvider.overrideWithValue(gitFiles ?? noGitFiles),
    if (database != null) databaseProvider.overrideWithValue(database),
    // A real periodic timer would outlive the widget tree and trip
    // flutter_test's pending-timer check; tests drive saving explicitly.
    scrollbackAutosaveFactoryProvider.overrideWithValue(
      ({required onTick}) => ScrollbackAutosave(
        onTick: onTick,
        schedule: (delay, callback) => Object(),
        cancel: (_) {},
      ),
    ),
    // Off unless a test says otherwise; also keeps the terminal controller
    // from pulling in settings (and therefore a database) just to open a pane.
    shellIntegrationEnabledProvider.overrideWithValue(shellIntegration),
    // Pinned, because the real list is host-shaped: a Mac offers the shells in
    // its /etc/shells and no `cmd`, so a test naming a profile would pass or
    // fail according to the machine it ran on.
    terminalProfilesProvider.overrideWithValue(const [
      TerminalProfile.powerShell,
      TerminalProfile.commandPrompt,
    ]),
    // Defaulted to what production ships, so the whole suite exercises the real
    // restore: a pane that was running when the app closed comes back running.
    // Same seam and same reason as the line above — reading the setting would
    // drag a database into every terminal test.
    restoreLivePanesProvider.overrideWithValue(restoreLivePanes),
    // The delivery strip polls `gh` on a periodic timer, which would outlive
    // the widget tree and trip the pending-timer check in every test that
    // renders a session. Same reason as the autosave above; tests that care
    // about polling drive it explicitly.
    deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
    // The session bar's usage chip has its own timer, and the same problem: it
    // is drawn by every test that renders a session, and a live tick would be
    // pending when the test ends. Zero means no timer; the tests that are about
    // the schedule hand back a real floor.
    usagePollFloorProvider.overrideWithValue(usagePollFloor),
    // **And the chip's service is faked by default.** The chip moved from the
    // window's status bar — which a handful of tests draw — into the session
    // bar, which ninety-odd of them draw, and the real `AgentUsageService`
    // locates CLI stores on the host and reads credentials off disk before it
    // gives up. Nothing in a widget test wants that, and no test may ever make
    // a live request. A test that has something to say about usage hands its
    // own service in here rather than adding a second override, because
    // Riverpod refuses the same provider twice in one container.
    agentUsageServiceProvider.overrideWithValue(
      usageService ?? FakeAgentUsageService(),
    ),
    // [instanceFactory] replaces the default rather than adding a second
    // override: Riverpod refuses the same provider twice in one container, so a
    // test that needs a pane to fail has to substitute here.
    terminalInstanceFactoryProvider.overrideWithValue(
      instanceFactory ?? defaultFakeInstanceFactory,
    ),
  ];
}

/// The factory behind [fakeTerminalOverrides]: a process-free pane for whatever
/// it is asked to build.
TerminalInstance defaultFakeInstanceFactory({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
}) => FakeTerminalInstance(
  id: id,
  title: agentLaunch?.title ?? agentLaunch?.agentId ?? profile.label,
  profileId: agentLaunch?.profileId ?? profile.id,
  workingDirectory: workingDirectory,
  restored: restoredScrollback,
  agentLaunch: agentLaunch,
  adoptTerminal: adoptTerminal,
  shellIntegration: shellIntegration,
);
