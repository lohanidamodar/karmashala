import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/terminal/application/scrollback_autosave.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/command_block_recorder.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

/// A process-free [TerminalInstance] so the controller can be tested without
/// spawning a real PTY.
class FakeTerminalInstance implements TerminalInstance {
  FakeTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    this.workingDirectory,
    this.restored,
    this.agentLaunch,
  }) {
    terminal = Terminal(maxLines: 1000)..resize(40, 10);
    if (restored != null && restored!.isNotEmpty) terminal.write(restored!);
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;
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

  /// The fake never runs a shell, so it has no command boundaries.
  @override
  CommandBlockRecorder? get commandBlocks => null;

  /// Live until disposed, so the fake exercises the same detach/end paths a
  /// real PTY does.
  @override
  ValueListenable<PaneLiveness> get liveness => livenessNotifier;
  final livenessNotifier = ValueNotifier(PaneLiveness.live);

  bool disposed = false;

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    livenessNotifier.value = PaneLiveness.exited;
    livenessNotifier.dispose();
    focusNode.dispose();
    scrollController.dispose();
  }
}

/// A container whose terminals are fakes, optionally over a real in-memory
/// database so persistence can be exercised.
ProviderContainer fakeTerminalContainer({AppDatabase? database}) =>
    ProviderContainer(overrides: fakeTerminalOverrides(database: database));

/// The overrides behind [fakeTerminalContainer], so a test that needs more of
/// them can spread this list rather than reproduce a second, friendlier fake.
///
/// The return type is inferred on purpose: Riverpod's `Override` is a sealed
/// type its public library does not export, so it cannot be written down here.
// ignore: strict_top_level_inference
fakeTerminalOverrides({
  AppDatabase? database,
  TerminalInstanceFactory? instanceFactory,
}) {
  return [
    if (database != null) databaseProvider.overrideWithValue(database),
    // A real periodic timer would outlive the widget tree and trip
    // flutter_test's pending-timer check; tests drive saving explicitly.
    scrollbackAutosaveFactoryProvider.overrideWithValue(
      ({required onTick}) => ScrollbackAutosave(
        onTick: onTick,
        schedule: (interval, callback) => Object(),
        cancel: (_) {},
      ),
    ),
    // Off unless a test says otherwise; also keeps the terminal controller
    // from pulling in settings (and therefore a database) just to open a pane.
    shellIntegrationEnabledProvider.overrideWithValue(false),
    // The delivery strip polls `gh` on a periodic timer, which would outlive
    // the widget tree and trip the pending-timer check in every test that
    // renders a session. Same reason as the autosave above; tests that care
    // about polling drive it explicitly.
    deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
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
}) => FakeTerminalInstance(
  id: id,
  title: agentLaunch?.title ?? agentLaunch?.agentId ?? profile.label,
  profileId: agentLaunch?.profileId ?? profile.id,
  workingDirectory: workingDirectory,
  restored: restoredScrollback,
  agentLaunch: agentLaunch,
);
