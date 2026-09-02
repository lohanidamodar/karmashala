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
import '../domain/osc_router.dart';
import '../domain/pane_liveness.dart';
import '../domain/scrollback_limits.dart';
import '../domain/shell_integration.dart';
import '../domain/terminal_profile.dart';
import '../domain/working_directory_osc.dart';
import 'cold_screen.dart';
import 'command_block_recorder.dart';
import 'process_shutdown.dart';
import 'pty_launch.dart';
import 'pty_output_coalescer.dart';
import 'terminal_ingest_budget.dart';

/// One open terminal: a stable [id]/[title] and the xterm [Terminal] buffer the
/// UI renders. Implementations own whatever backs the buffer (a real PTY in
/// production, nothing in tests).
abstract class TerminalInstance {
  String get id;
  String get title;
  Terminal get terminal;

  /// The [TerminalProfile] id this pane was launched from — kept so the pane
  /// can be recreated after a restart.
  String get profileId;

  /// The directory the pane is in **now**: where it was launched until the
  /// shell says it has moved (OSC 7), and where it has moved to after that.
  ///
  /// Live rather than fixed because everything that reads it wants the current
  /// answer, not the launch one: relative-path link resolution joins onto it,
  /// the tab label is derived from it, the workspace record a pane is restored
  /// from stores it, and the MCP terminal tools report it.
  String? get workingDirectory;

  /// [workingDirectory] as something to listen to.
  ///
  /// Listenable for exactly the reason [liveness] is — so the tab label follows
  /// a `cd` without anything polling for one. Notifies once per *change*: a
  /// shell that re-emits OSC 7 on every prompt redraw says nothing new.
  ValueListenable<String?> get directory;

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

/// A [TerminalInstance] whose parsed buffer can be handed to the pane that
/// replaces it.
///
/// Starting a process in a pane that already has one's worth of history means
/// building a new instance, because a dormant pane and a running one are
/// different things. What it does *not* have to mean is rebuilding the history:
/// the old pane's buffer already holds it, parsed, and the round trip through
/// the codec — encode 256 KiB out, parse 256 KiB back in — is 10-25 ms of
/// main-isolate work to arrive at the buffer we started with. Handing the
/// buffer over instead costs nothing at all.
///
/// A fourth narrow interface for the same reason as the three above: `null` is
/// the answer for every pane whose history is *text* rather than a buffer — a
/// parked one gave its buffer up on purpose, and a dormant one that has never
/// been looked at has not built its buffer yet, so adopting it would perform
/// exactly the parse this exists to avoid.
abstract interface class AdoptableTerminalInstance {
  /// The buffer holding this pane's history, or `null` when there is none to
  /// hand over.
  Terminal? get adoptableBuffer;
}

/// A [ValueListenable] that holds one value and never notifies.
///
/// What [TerminalInstance.directory] is for a pane whose shell can never report
/// one: an error pane never started a process, and a dormant pane is replayed
/// history. Allocated once per instance rather than per read, so adding and
/// removing a listener reach the same object.
class UnchangingValue<T> implements ValueListenable<T> {
  const UnchangingValue(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// A pane's working directory: the one it launched in, then whatever the shell
/// reports with OSC 7.
///
/// A [ValueNotifier] on purpose — it drops a write of the value it already
/// holds, which is the whole of the "one republish per `cd`" rule. A shell that
/// emits OSC 7 from its prompt function emits it on every redraw, and that must
/// cost nothing.
class WorkingDirectoryTracker {
  WorkingDirectoryTracker(String? launchedIn, {String? hostname})
    : _hostname = hostname ?? localHostname,
      _directory = ValueNotifier(launchedIn);

  /// This machine's name, read once: a syscall, and it cannot change while the
  /// app runs. Null when the host will not say, which makes every named host
  /// foreign — see [workingDirectoryFromOsc].
  static final String? localHostname = () {
    try {
      return Platform.localHostname;
    } catch (_) {
      return null;
    }
  }();

  final ValueNotifier<String?> _directory;
  final String? _hostname;
  bool _disposed = false;

  ValueListenable<String?> get listenable => _directory;

  String? get value => _directory.value;

  /// One OSC from the pane's [OscRouter].
  ///
  /// A sequence we cannot read leaves the directory alone: `null` from the
  /// parser means *no answer*, never *the pane has no directory*.
  void handleOsc(String code, List<String> args) {
    if (_disposed) return;
    final reported = workingDirectoryFromOsc(code, args, hostname: _hostname);
    if (reported != null) _directory.value = reported;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _directory.dispose();
  }
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
      Terminal? adoptTerminal,
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
        ParkableTerminalInstance,
        AdoptableTerminalInstance {
  PtyTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required PtyLaunch launch,
    String? workingDirectory,
    this.agentLaunch,
    String? restoredScrollback,
    bool shellIntegration = false,
    TerminalIngestBudget? ingestBudget,
    Terminal? adoptTerminal,
  }) : _cwd = WorkingDirectoryTracker(workingDirectory) {
    // The buffer the pane this one replaces was already holding, when there is
    // one. Handlers are set either way rather than only on the fresh path: the
    // two are the same values, and a branch here is a branch that can drift.
    terminal = (adoptTerminal ?? Terminal(maxLines: kLiveScrollbackMaxLines))
      // xterm 4.0.0 reports the wheel with the wrong button ids, which stops
      // tmux (and anything else reading the modifier bits) from scrolling.
      ..mouseHandler = const KarmashalaMouseHandler()
      // ...and encodes every modified Enter as a bare CR, so Shift+Enter is
      // indistinguishable from submit.
      ..inputHandler = const KarmashalaInputHandler()
      // The pane owns xterm's single OSC slot for its whole life and fans it
      // out, because two unrelated things read it — OSC 133 command blocks,
      // which exist only with shell integration on, and the OSC 7 working
      // directory, which must work either way.
      ..onPrivateOSC = _osc.dispatch;
    // Registered before the process starts, so no sequence can be missed. The
    // directory listens unconditionally: plenty of shells emit OSC 7 with no
    // help from us, and integration is about OSC 133.
    _osc.add(_cwd.handleOsc);
    if (shellIntegration) {
      commandBlocks = CommandBlockRecorder(terminal)..attach(_osc);
    }
    // Replay the previous session's scrollback *before* the shell starts, so
    // restored history sits above the new process's first output. An adopted
    // buffer is that history already, so it needs only the marker that says
    // where it ends.
    if (adoptTerminal == null) {
      writeRestoredScrollback(terminal, restoredScrollback);
    } else {
      writeRestoreMarker(terminal);
    }
    // flutter_pty only forwards a tiny allowlist of env vars to the child; pass
    // the host environment so Windows shells get SystemRoot/WINDIR/etc. (without
    // them powershell.exe/cmd.exe and wsl.exe fail to start) — sanitized so a
    // POSIX env leaked from launching via WSL doesn't break wsl.exe.
    final startIn =
        (launch.workingDirectory != null &&
            Directory(launch.workingDirectory!).existsSync())
        ? launch.workingDirectory
        : null;
    _pty = Pty.start(
      launch.executable,
      arguments: launch.arguments,
      environment: _ptyEnvironment(launch.environment),
      workingDirectory: startIn,
    );

    // Buffer the raw PTY bytes and hand them to the terminal once per frame.
    // flutter_pty reads 1 KB at a time, so without this a busy shell costs
    // hundreds of decodes, parses and notifyListeners() a second on the UI
    // isolate — which is what the streaming stutter was.
    _coalescer = PtyOutputCoalescer(
      onData: terminal.write,
      budget: ingestBudget,
    );
    _cold = ColdIngest(terminal: terminal, budget: ingestBudget);
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

  /// Seeded with the directory the pane launched in, then kept current by the
  /// shell's own OSC 7.
  final WorkingDirectoryTracker _cwd;

  @override
  String? get workingDirectory => _cwd.value;

  @override
  ValueListenable<String?> get directory => _cwd.listenable;

  /// Owns `terminal.onPrivateOSC` for this pane's whole life and fans it out —
  /// see the constructor.
  final OscRouter _osc = OscRouter();

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

  IngestTier _tier = IngestTier.hot;

  /// Where this pane's output goes, and what redraws its screen, while nobody
  /// can see it. Also what decides whether it parks at all.
  late final ColdIngest _cold;

  @override
  IngestTier get ingestTier => _tier;

  @override
  String? get parkedScrollback => _cold.parkedScrollback;

  /// This pane's buffer, once its process has gone and while the buffer really
  /// is the history.
  ///
  /// Three conditions, and it takes all three. The process has to have
  /// **exited**, because a running pane's buffer is not anybody else's to take.
  /// The pane must not be **parked**, because a parked one gave its buffer up
  /// and holds its history in [parkedScrollback] instead. And it must not be on
  /// the **alternate buffer**, because that is a full-screen program's scratch
  /// space rather than scrollback — the codec has always encoded only the main
  /// buffer, and handing the alternate one over would restart the pane showing
  /// a stale TUI frame.
  @override
  Terminal? get adoptableBuffer =>
      _exited && !_cold.isParked && !terminal.isUsingAltBuffer ? terminal : null;

  /// Bytes this pane is holding for a replay. Diagnostics, and what the
  /// ingest-tier tests assert on.
  @visibleForTesting
  int get spooledBytes => _cold.spooledBytes;

  /// Reads the pipe. A pane nobody can see does not parse its output stream:
  /// its bytes go to [ColdIngest], which keeps only the screen readable and
  /// holds the rest undecoded. Something still has to *read* the pipe, or the
  /// child blocks on a full OS buffer.
  void _onPtyBytes(Uint8List bytes) {
    if (_disposed) return;
    if (_tier == IngestTier.cold) {
      _cold.add(bytes);
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
      // Hand over what is already queued rather than parsing it on the way out:
      // going cold must not cost a flush of the coalescer.
      if (_cold.detach(_coalescer.takePending())) {
        // The blocks whose prompt line just went are what held those lines
        // alive, through their anchors; dropping them is what actually releases
        // the memory. A replayed window carries no OSC 133 markers anyway, so
        // there is nothing left for them to point at when the pane comes back.
        commandBlocks?.tracker.pruneEvicted();
      }
    } else if (wasCold) {
      _cold.reattach();
    }
  }

  /// Writes text the app generated wherever this pane's output is going — the
  /// buffer while it is visible, and [ColdIngest] while it is not.
  void _emit(String text) {
    if (_tier == IngestTier.cold) {
      _cold.emit(text);
      return;
    }
    terminal.write(text);
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
    // After this the tracker ignores OSC rather than writing to a disposed
    // notifier — the parser can still flush a sequence it was part-way through.
    _cwd.dispose();
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
  terminal.write(scrollback);
  writeRestoreMarker(terminal);
}

/// Writes the dim marker that says where replayed history ends and the live
/// process begins.
///
/// Its own function because a pane that **adopted** the previous one's buffer
/// has the history already and needs only this — see
/// [AdoptableTerminalInstance].
void writeRestoreMarker(Terminal terminal) {
  final at = DateTime.now();
  final stamp =
      '${at.year}-${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}:${_two(at.minute)}';
  terminal.write(
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
    Terminal? adoptTerminal,
  }) {
    // A failed *restart* still has the history the pane it replaced was
    // holding, and that history is the reason anyone would retry. Adopting the
    // buffer here is what stops a spawn failure throwing it away — the pane
    // that could not start is the one whose scrollback matters most.
    terminal = adoptTerminal ?? Terminal(maxLines: kErrorPaneScrollbackMaxLines);
    if (adoptTerminal == null) {
      writeRestoredScrollback(terminal, restoredScrollback);
    }
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

  /// An error pane never started a shell, so nothing can ever report a `cd`.
  @override
  late final ValueListenable<String?> directory = UnchangingValue(
    workingDirectory,
  );

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
///
/// A launch does restart *some* panes now — the shells of the active tab that
/// were running when the app closed. Those are built as live panes instead of
/// this one, so nothing here changed: the argument above is still the reason
/// every other stored pane arrives dormant. `shouldRestartOnLaunch` is where
/// the line is drawn.
class DormantTerminalInstance
    implements TerminalInstance, AdoptableTerminalInstance {
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

  /// Replayed history with nothing running behind it: the directory it holds is
  /// the one the pane was last observed in, and nothing here can move it.
  @override
  late final ValueListenable<String?> directory = UnchangingValue(
    workingDirectory,
  );

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

  /// The buffer, but only once something has already built it.
  ///
  /// A pane the workbench has shown has parsed its stored scrollback once, and
  /// starting a process in it must not parse the same text a second time. A
  /// pane nobody has looked at has no buffer to hand over, and building one to
  /// hand over would *be* the parse — so it declines, and the pane replacing it
  /// replays the text as before.
  @override
  Terminal? get adoptableBuffer =>
      _bufferBuilt && restoredScrollback.isNotEmpty ? terminal : null;

  Terminal _buildTerminal() {
    _bufferBuilt = true;
    final built = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..mouseHandler = const KarmashalaMouseHandler()
      ..inputHandler = const KarmashalaInputHandler();
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
  Terminal? adoptTerminal,
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
      adoptTerminal: adoptTerminal,
    );
  } catch (e) {
    final args = describeLaunchArguments(launch.arguments);
    return ErrorTerminalInstance(
      id: id,
      title: title,
      profileId: profileId,
      workingDirectory: workingDirectory,
      agentLaunch: agentLaunch,
      restoredScrollback: restoredScrollback,
      adoptTerminal: adoptTerminal,
      message:
          'Failed to start "${launch.executable} $args"'
          '${launch.workingDirectory == null ? '' : ' in ${launch.workingDirectory}'}: $e',
    );
  }
}

/// The longest an argument may be before it is summarised rather than printed.
///
/// Generous enough that an ordinary path, flag or prompt fragment survives
/// whole: what this is for is the outliers.
const int _maxArgumentInMessage = 120;

/// [arguments] as one line, with anything unreadably long summarised.
///
/// A shell-integrated PowerShell pane is launched with `-EncodedCommand` and a
/// base64 blob that runs to ~4,600 characters. Printed verbatim into a pane
/// that failed to start, it pushed the one sentence that explains the failure —
/// the exception, at the end — off the visible buffer, so the error message
/// hid its own error message. The length is kept because "it was 4,612
/// characters" is occasionally the diagnosis, and the flag before it is kept
/// because that is what says which argument got elided.
String describeLaunchArguments(List<String> arguments) => [
  for (final argument in arguments)
    if (argument.length <= _maxArgumentInMessage)
      argument
    else
      '<${argument.length} characters elided>',
].join(' ');
