import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../domain/agent_pane_launch.dart';
import '../domain/enter_key_encoding.dart';
import '../domain/ingest_tier.dart';
import '../domain/launch_context.dart';
import '../domain/mouse_wheel_reporter.dart';
import '../domain/pane_liveness.dart';
import '../domain/scrollback_limits.dart';
import '../domain/shell_integration.dart';
import '../domain/terminal_profile.dart';
import 'command_block_recorder.dart';
import 'process_shutdown.dart';
import 'pty_launch.dart';
import 'scrollback_park.dart';
import 'pty_output_coalescer.dart';
import 'scrollback_spool.dart';
import 'terminal_ingest_budget.dart';

/// One open terminal: a stable [id]/[title] and the xterm [Terminal] buffer the
/// UI renders. Implementations own whatever backs the buffer (a real PTY in
/// production, nothing in tests).
abstract class TerminalInstance {
  String get id;
  String get title;
  Terminal get terminal;

  /// The [TerminalProfile] id this pane was launched from, and the directory it
  /// started in — kept so the pane can be recreated after a restart.
  String get profileId;
  String? get workingDirectory;

  /// The agent CLI this pane runs, or `null` for a plain shell.
  ///
  /// Recorded rather than derived because restoring the pane has to reproduce
  /// the exact command line, and a profile id alone cannot: it does not know
  /// which installation's executable was used, which permission flags applied,
  /// or which session it belonged to.
  AgentPaneLaunch? get agentLaunch;

  /// Whether a process is running behind [terminal], and why not when there is
  /// none. Listenable so a pane stops advertising itself as live the moment its
  /// process exits, without the controller polling for it.
  ValueListenable<PaneLiveness> get liveness;

  /// The status the process exited with, once it has.
  ///
  /// Null while it is running, and null for a pane that never ran one — and
  /// also for an instance that cannot know, which is why the default is here
  /// rather than on every implementor. Read by the collapse-on-exit rule: a
  /// clean exit is a shell being dismissed, a failure is output someone is
  /// about to read.
  int? get exitCode => null;

  /// Drives selection/scroll for the view — read to copy the current selection.
  TerminalController get controller;

  /// Owned by the instance rather than the widget so the app can focus a pane
  /// and scroll it to a search hit without reaching into the widget tree.
  FocusNode get focusNode;
  ScrollController get scrollController;

  /// OSC 133 command boundaries for this pane, or `null` when the shell was
  /// not integrated. Null — not an empty tracker — so the UI can tell "no
  /// integration" from "integrated, but nothing run yet" and stay invisible in
  /// the first case.
  CommandBlockRecorder? get commandBlocks;

  /// Tears down the backing process/streams. Safe to call more than once.
  void dispose();
}

/// A [TerminalInstance] whose teardown outlives its `dispose()`.
///
/// Deliberately a second, narrower interface: most panes have nothing to reap —
/// an error pane never spawned anything and a dormant pane is replayed history,
/// not a process — and only the ones that do should make a caller wait.
///
/// [dispose] stays synchronous because panes are closed from build callbacks,
/// but ending a real pane on Windows means spawning `taskkill /PID <pid> /T /F`
/// (see `killWindowsProcessTree`). Dropping that future is fine when a tab is
/// closed and the app keeps running; on quit it meant `windowManager.destroy()`
/// ended the process while the kill was still in flight, orphaning the dev
/// server, build or ssh session the user had running inside the pane.
abstract interface class ReapableTerminalInstance {
  /// Completes once the process tree behind this pane is gone.
  ///
  /// A future that is already complete before [TerminalInstance.dispose] is
  /// called, so awaiting it is always safe.
  Future<void> get reaped;
}

/// A [TerminalInstance] whose output ingestion answers to how visible it is.
///
/// Deliberately a second, narrower interface, for the same reason
/// [ReapableTerminalInstance] is one: most panes have nothing to throttle. An
/// error pane never spawned anything, a dormant pane is replayed history, and a
/// test fake produces output only when a test says so. Only a pane with a live
/// pipe behind it has a tier worth setting.
///
/// The controller sets this from the only thing that decides it — where the
/// pane is in the workspace. A pane never chooses its own tier.
abstract interface class TieredTerminalInstance {
  /// How visible this pane is now.
  void setIngestTier(IngestTier tier);

  /// What it was last told.
  IngestTier get ingestTier;
}

/// A [TerminalInstance] that gives its scrollback back while it is cold.
///
/// The storage half of the ingest tiers, and a third narrow interface for the
/// same reason as [ReapableTerminalInstance] and [TieredTerminalInstance]: only
/// a pane with a live pipe behind it has a buffer worth parking. An error pane
/// holds one line, a dormant pane *is* its stored text already, and a test fake
/// has nothing to release.
///
/// While a pane is parked its parsed buffer holds only the screen, and the
/// history above it lives here as encoded text. That makes this the pane's
/// scrollback for as long as it lasts: the controller stores it verbatim rather
/// than re-encoding a buffer that no longer has anything in it.
abstract interface class ParkableTerminalInstance {
  /// The encoded window held in place of a parsed buffer, or `null` when this
  /// pane's scrollback is live.
  String? get parkedScrollback;
}

/// Signature for creating a [TerminalInstance] — injected so tests can supply a
/// process-free fake (a real [Pty] would try to spawn a shell).
typedef TerminalInstanceFactory =
    TerminalInstance Function({
      required String id,
      required TerminalProfile profile,
      String? workingDirectory,
      String? restoredScrollback,
      bool shellIntegration,
      AgentPaneLaunch? agentLaunch,
    });

/// A [TerminalInstance] backed by a real host ConPTY ([Pty]) wired to an xterm
/// [Terminal]: PTY output is decoded into the buffer, keystrokes are encoded
/// back to the PTY, and terminal resizes are forwarded.
///
/// This is the one deliberate exception to the `CommandRunner` rule
/// (architecture constraint 6): an interactive terminal needs a pseudo-terminal,
/// which the run-to-completion/stream abstraction does not model.
class PtyTerminalInstance
    implements
        TerminalInstance,
        ReapableTerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance {
  PtyTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required PtyLaunch launch,
    this.workingDirectory,
    this.agentLaunch,
    String? restoredScrollback,
    bool shellIntegration = false,
    TerminalIngestBudget? ingestBudget,
  }) {
    terminal = Terminal(maxLines: kLiveScrollbackMaxLines)
      // xterm 4.0.0 reports the wheel with the wrong button ids, which stops
      // tmux (and anything else reading the modifier bits) from scrolling.
      ..mouseHandler = const ChitraguptaMouseHandler()
      // ...and encodes every modified Enter as a bare CR, so Shift+Enter is
      // indistinguishable from submit.
      ..inputHandler = const ChitraguptaInputHandler();
    // Attach before the process starts so no marker can be missed. When the
    // shell is not integrated this stays null and nothing else changes.
    if (shellIntegration) {
      commandBlocks = CommandBlockRecorder(terminal)..attach();
    }
    // Replay the previous session's scrollback *before* the shell starts, so
    // restored history sits above the new process's first output.
    writeRestoredScrollback(terminal, restoredScrollback);
    // flutter_pty only forwards a tiny allowlist of env vars to the child; pass
    // the host environment so Windows shells get SystemRoot/WINDIR/etc. (without
    // them powershell.exe/cmd.exe and wsl.exe fail to start) — sanitized so a
    // POSIX env leaked from launching via WSL doesn't break wsl.exe.
    final workingDirectory =
        (launch.workingDirectory != null &&
            Directory(launch.workingDirectory!).existsSync())
        ? launch.workingDirectory
        : null;
    _pty = Pty.start(
      launch.executable,
      arguments: launch.arguments,
      environment: _ptyEnvironment(launch.environment),
      workingDirectory: workingDirectory,
    );

    // Buffer the raw PTY bytes and hand them to the terminal once per frame.
    // flutter_pty reads 1 KB at a time, so without this a busy shell costs
    // hundreds of decodes, parses and notifyListeners() a second on the UI
    // isolate — which is what the streaming stutter was.
    _coalescer = PtyOutputCoalescer(
      onData: terminal.write,
      budget: ingestBudget,
    );
    _outputSubscription = _pty.output.listen(_onPtyBytes);

    // Captured while the process is certainly alive: `pid` is only safe to act
    // on before the OS can recycle the number.
    _pid = _pty.pid;

    _pty.exitCode.then((code) {
      _exited = true;
      _exitCode = code;
      if (_disposed) return;
      _emit('\r\n\x1b[90m[process exited with code $code]\x1b[0m\r\n');
      // The buffer stays on screen, but the pane is no longer a terminal you
      // can type into — say so, so the UI can stop drawing it as one.
      _liveness.value = PaneLiveness.exited;
    });

    terminal.onOutput = (data) {
      if (_disposed) return;
      try {
        _pty.write(const Utf8Encoder().convert(data));
      } catch (_) {
        // The PTY has gone away — ignore late keystrokes.
      }
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_disposed) return;
      try {
        _pty.resize(height, width);
      } catch (_) {}
    };
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
  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();
  @override
  CommandBlockRecorder? commandBlocks;

  @override
  ValueListenable<PaneLiveness> get liveness => _liveness;

  int? _exitCode;

  @override
  int? get exitCode => _exitCode;
  final _liveness = ValueNotifier(PaneLiveness.live);

  late final Pty _pty;
  late final PtyOutputCoalescer _coalescer;
  late final StreamSubscription<Uint8List> _outputSubscription;
  late final int _pid;
  bool _disposed = false;
  bool _exited = false;
  Future<void>? _reap;

  /// Where a cold pane's output goes instead of into the parser.
  final ScrollbackSpool _spool = ScrollbackSpool();

  IngestTier _tier = IngestTier.hot;

  /// The scrollback this pane gives up while it is cold.
  late final ScrollbackPark _park = ScrollbackPark(terminal);

  @override
  IngestTier get ingestTier => _tier;

  @override
  String? get parkedScrollback => _park.parked;

  /// Bytes the spool discarded while this pane was cold. Diagnostics, and what
  /// the replay reads to decide whether to admit to a gap.
  @visibleForTesting
  int get spooledBytes => _spool.length;

  /// Reads the pipe. A pane nobody can see does not parse: its bytes go
  /// straight into a bounded spool, undecoded, and are replayed only if the
  /// session comes back. Something still has to *read* the pipe, or the child
  /// blocks on a full OS buffer.
  void _onPtyBytes(Uint8List bytes) {
    if (_disposed) return;
    if (_tier == IngestTier.cold) {
      _spool.add(bytes);
      return;
    }
    _coalescer.add(bytes);
  }

  @override
  void setIngestTier(IngestTier tier) {
    if (_disposed || _tier == tier) return;
    final wasCold = _tier == IngestTier.cold;
    _tier = tier;
    _coalescer.tier = tier;
    if (tier == IngestTier.cold) {
      // Take what is already queued with us rather than parsing it on the way
      // out: going cold must not cost a flush.
      _spool.add(_coalescer.takePending());
      if (_park.park()) {
        // The blocks whose prompt line just went are what held those lines
        // alive, through their anchors; dropping them is what actually releases
        // the memory. A replayed window carries no OSC 133 markers anyway, so
        // there is nothing left for them to point at when the pane comes back.
        commandBlocks?.tracker.pruneEvicted();
      }
    } else if (wasCold) {
      _park.unpark();
      _replaySpool();
    }
  }

  /// Writes text the app generated wherever this pane's output is going.
  ///
  /// A cold pane is not parsing, so its notice belongs in the spool among the
  /// process output it arrived with — writing it into a parked buffer would put
  /// it above history that came before it.
  void _emit(String text) {
    if (_tier == IngestTier.cold) {
      _spool.add(const Utf8Encoder().convert(text));
      return;
    }
    terminal.write(text);
  }

  /// Writes what arrived while this pane was cold into its buffer.
  ///
  /// One write, bounded by the spool's own cap, so bringing a session back is
  /// a single parse of at most a few hundred screens rather than however much
  /// the process produced while it was away.
  void _replaySpool() {
    final dropped = _spool.droppedBytes;
    final bytes = _spool.drain();
    _spool.reset();
    if (bytes.isEmpty && dropped == 0) return;
    if (dropped > 0) {
      terminal.write(
        '\r\n\x1b[90m[\u2026 ${dropped ~/ 1024} KiB of output while '
        'detached was dropped]\x1b[0m\r\n',
      );
    }
    if (bytes.isNotEmpty) {
      terminal.write(const Utf8Decoder(allowMalformed: true).convert(bytes));
    }
  }

  @override
  Future<void> get reaped => _reap ?? Future<void>.value();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Set before disposing: a listener still attached deserves the final state,
    // and a ValueNotifier throws if written to after disposal.
    _liveness.value = PaneLiveness.exited;
    _liveness.dispose();
    unawaited(_outputSubscription.cancel());
    _coalescer.dispose();
    focusNode.dispose();
    scrollController.dispose();
    // Ask the process to exit before destroying it. A bare kill is wrong for
    // anything long-running — a build, a dev server, an ssh session, a database
    // client mid-write — because the process never gets to flush or run its
    // exit handlers. This runs on app quit as well as tab close.
    //
    // Kept rather than dropped: closing a tab does not have to wait for the
    // kill, but quitting does — see [reaped].
    _reap = shutdownProcess(
      kill: _pty.kill,
      exitCode: _pty.exitCode,
      // The whole tree, not just the pid: see killWindowsProcessTree.
      pid: _exited ? null : _pid,
    );
  }
}

/// Writes [scrollback] into [terminal] followed by a dim marker, so the user can
/// see where replayed history ends and the live process begins.
///
/// Does nothing when there is nothing to restore.
void writeRestoredScrollback(Terminal terminal, String? scrollback) {
  if (scrollback == null || scrollback.isEmpty) return;
  final at = DateTime.now();
  final stamp =
      '${at.year}-${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}:${_two(at.minute)}';
  terminal
    ..write(scrollback)
    ..write(
      '\r\n\x1b[90m\u2500\u2500 restored \u2500 $stamp '
      '\u2500\u2500\x1b[0m\r\n',
    );
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Builds the environment for a Windows PTY child.
///
/// Normally this is just the host environment. But when the app is launched from
/// a WSL/Unix shell (e.g. `flutter run -d windows` from fish), a POSIX `PATH`
/// (`/usr/bin:/bin:…`), `SHELL=/usr/bin/fish` and `WSL*` interop vars leak into
/// the Windows process. Handing those to `wsl.exe`/`powershell.exe` breaks them,
/// so we rebuild a clean Windows `Path` and drop the Unix leak.
Map<String, String> _ptyEnvironment([Map<String, String> extra = const {}]) {
  final env = Map<String, String>.of(Platform.environment);

  // WSL-interop / Unix-shell leaks (present only when launched from WSL); these
  // confuse wsl.exe and the Windows shells. Harmless no-ops on a clean launch.
  final shell = env['SHELL'];
  if (shell != null && shell.startsWith('/')) env.remove('SHELL');
  env
    ..remove('WSLENV')
    ..remove('WSL_INTEROP')
    ..remove('WSL_DISTRO_NAME');

  // A POSIX PATH means we were launched from a Unix shell — rebuild a Windows
  // PATH so wsl.exe / powershell.exe / cmd.exe resolve.
  final path = env['Path'] ?? env['PATH'];
  if (path != null && path.startsWith('/')) {
    final sysRoot = env['SystemRoot'] ?? env['windir'] ?? r'C:\Windows';
    env
      ..remove('PATH')
      ..['Path'] =
          '$sysRoot\\System32;$sysRoot;'
          '$sysRoot\\System32\\WindowsPowerShell\\v1.0;'
          '$sysRoot\\System32\\wbem';
  }

  // Layered last so a caller's variables survive the WSL-leak scrubbing above —
  // an agent pane sets WSLENV deliberately, and it must not be the one that was
  // just removed.
  env.addAll(extra);
  return env;
}

/// A [TerminalInstance] that failed to spawn: it renders the error in its buffer
/// so the panel surfaces *why* instead of crashing the app.
class ErrorTerminalInstance implements TerminalInstance {
  ErrorTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required String message,
    this.workingDirectory,
    this.agentLaunch,
    String? restoredScrollback,
  }) {
    terminal = Terminal(maxLines: kErrorPaneScrollbackMaxLines);
    writeRestoredScrollback(terminal, restoredScrollback);
    terminal.write('\x1b[91m$message\x1b[0m\r\n');
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
  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  /// An error pane never runs a shell, so it never has command boundaries.
  @override
  CommandBlockRecorder? get commandBlocks => null;

  /// Nothing ran here, so nothing exited.
  @override
  int? get exitCode => null;

  /// Nothing is running: the spawn failed. The pane therefore offers the same
  /// "start it" affordance a restored pane does, which doubles as a retry.
  @override
  final ValueListenable<PaneLiveness> liveness = const _Constant(
    PaneLiveness.exited,
  );

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    focusNode.dispose();
    scrollController.dispose();
  }
}

/// A [ValueListenable] whose value never changes, so a pane with no process
/// does not have to own (and tear down) a notifier that can never fire.
class _Constant<T> implements ValueListenable<T> {
  const _Constant(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// A [TerminalInstance] rebuilt from a stored record with **no process behind
/// it**: the pane the user left, replayed, waiting to be started again.
///
/// This is the restore path's whole point. Spawning a shell for every stored
/// pane at launch would make dead history indistinguishable from a live
/// terminal, and — once a pane records a launch command rather than just a
/// profile — would re-execute it. A dormant pane re-executes nothing; the user
/// starts it, or does not.
class DormantTerminalInstance implements TerminalInstance {
  DormantTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required this.restoredScrollback,
    this.workingDirectory,
    this.agentLaunch,
  });

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

  /// The stored scrollback exactly as it was read back.
  ///
  /// Kept as the original string rather than re-encoded from [terminal] so that
  /// starting the pane replays precisely what was restored, with no second
  /// round-trip through the codec and no duplicated restore marker.
  final String restoredScrollback;

  /// Parsed only when something asks to see it.
  ///
  /// A restored workspace can hold a hundred of these, and every one used to
  /// parse its stored scrollback into a 10 000-line `Terminal` during startup,
  /// for tabs the user may never open. `late final` makes that the first
  /// reader's cost instead — and since [restoredScrollback] is what the
  /// controller stores and what starting the pane replays, most of them are
  /// never built at all.
  @override
  late final Terminal terminal = _buildTerminal();

  /// Whether anything has asked to see this pane yet.
  ///
  /// The restore path's own measurement: the point of the laziness is that most
  /// panes of a restored workspace are never looked at, and `late final` cannot
  /// be asked whether it has run.
  @visibleForTesting
  bool get bufferBuilt => _bufferBuilt;
  bool _bufferBuilt = false;

  Terminal _buildTerminal() {
    _bufferBuilt = true;
    final built = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..mouseHandler = const ChitraguptaMouseHandler()
      ..inputHandler = const ChitraguptaInputHandler();
    if (restoredScrollback.isNotEmpty) built.write(restoredScrollback);
    return built;
  }

  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  /// No process ever ran here, so there are no command boundaries — the stored
  /// scrollback is text, not a record of what produced it.
  @override
  CommandBlockRecorder? get commandBlocks => null;

  /// Nothing ran here, so nothing exited.
  @override
  int? get exitCode => null;

  @override
  final ValueListenable<PaneLiveness> liveness = const _Constant(
    PaneLiveness.restored,
  );

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    focusNode.dispose();
    scrollController.dispose();
  }
}

/// Whether a pane launched this way gets an OSC 133 [CommandBlockRecorder].
///
/// Three conditions, all of them necessary:
///
/// * an agent pane runs the agent CLI directly, so there is no shell and no
///   prompt hook to emit markers;
/// * the user's setting has to be on;
/// * and the shell has to be one this app can make emit them
///   ([shellSupportsIntegration] — PowerShell today).
///
/// `ptyLaunchFor` has always applied the third rule to the *launch*; until
/// Loop 65 the factory did not apply it to the *recorder*, so every cmd.exe and
/// WSL pane got a live recorder and a permanent `onPrivateOSC` listener that no
/// marker could ever reach — and answered "yes" to *is this pane integrated?*,
/// which is what [TerminalInstance.commandBlocks] being nullable exists to say.
bool shellIntegrationApplies({
  required TerminalProfile profile,
  required bool shellIntegration,
  required AgentPaneLaunch? agentLaunch,
}) =>
    agentLaunch == null &&
    shellIntegration &&
    shellSupportsIntegration(profile.shell);

/// The production [TerminalInstanceFactory]: builds a [PtyLaunch] for the profile
/// and spawns a [PtyTerminalInstance], degrading to an [ErrorTerminalInstance]
/// (whose buffer shows the failure) if the PTY cannot be created.
TerminalInstance createPtyTerminalInstance({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
  AgentPaneLaunch? agentLaunch,
}) {
  // An agent pane runs the agent CLI itself, so the shell profile is not
  // consulted at all — the launch is built from the agent's registry descriptor
  // and its installation. Shell integration is meaningless here: OSC 133 markers
  // come from a shell's prompt hooks, and there is no shell.
  final PtyLaunch launch;
  final String title;
  final String profileId;
  final integrate = shellIntegrationApplies(
    profile: profile,
    shellIntegration: shellIntegration,
    agentLaunch: agentLaunch,
  );
  if (agentLaunch != null) {
    // The one place `Platform.isWindows` is turned into a launch context: from
    // here down the command is built for where it is going, not for where we
    // are — so a WSL launch made from inside that distro is not re-wrapped.
    launch = agentPtyLaunchFor(
      agentLaunch,
      context: LaunchContext.forAgent(
        agentLaunch,
        hostIsWindows: Platform.isWindows,
      ),
    );
    title = agentLaunch.title ?? agentLaunch.agentId;
    profileId = agentLaunch.profileId;
  } else {
    launch = ptyLaunchFor(
      profile,
      context: LaunchContext.forProfile(
        profile,
        hostIsWindows: Platform.isWindows,
        posixShell: Platform.environment['SHELL'],
      ),
      workingDirectory: workingDirectory,
      shellIntegration: integrate,
    );
    title = profile.label;
    profileId = profile.id;
  }
  try {
    return PtyTerminalInstance(
      id: id,
      title: title,
      profileId: profileId,
      launch: launch,
      workingDirectory: workingDirectory,
      agentLaunch: agentLaunch,
      restoredScrollback: restoredScrollback,
      shellIntegration: integrate && Platform.isWindows,
    );
  } catch (e) {
    final args = launch.arguments.join(' ');
    return ErrorTerminalInstance(
      id: id,
      title: title,
      profileId: profileId,
      workingDirectory: workingDirectory,
      agentLaunch: agentLaunch,
      restoredScrollback: restoredScrollback,
      message:
          'Failed to start "${launch.executable} $args"'
          '${launch.workingDirectory == null ? '' : ' in ${launch.workingDirectory}'}: $e',
    );
  }
}
