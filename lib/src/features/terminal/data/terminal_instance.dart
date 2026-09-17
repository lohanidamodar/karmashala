import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:karmashala_core/logging.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'cast_recorder.dart';
import 'cold_screen.dart';
import 'command_block_recorder.dart';
import 'process_shutdown.dart';
import 'pty_launch.dart';
import 'pty_output_coalescer.dart';
import 'terminal_grid_text.dart';
import 'terminal_ingest_budget.dart';

/// One open terminal: a stable [id]/[title] and the xterm [Terminal] buffer the
/// UI renders. Implementations own whatever backs the buffer.
abstract class TerminalInstance {
  String get id;
  String get title;
  Terminal get terminal;

  /// The [TerminalProfile] id this pane was launched from — kept so the pane
  /// can be recreated after a restart.
  String get profileId;

  /// The directory the pane is in **now**: where it launched until the shell
  /// says it has moved (OSC 7). Live, because every reader wants the current
  /// answer rather than the launch one.
  String? get workingDirectory;

  /// [workingDirectory] as something to listen to. Notifies once per *change* —
  /// a shell that re-emits OSC 7 on every prompt redraw says nothing new.
  ValueListenable<String?> get directory;

  /// The agent CLI this pane runs, or `null` for a plain shell. Recorded rather
  /// than derived: a profile id cannot reproduce the exact command line.
  AgentPaneLaunch? get agentLaunch;

  /// Whether a process is running behind [terminal], and why not when there is
  /// none. Listenable, so a pane stops advertising itself as live on exit.
  ValueListenable<PaneLiveness> get liveness;

  /// The status the process exited with, once it has. Null while it runs, for a
  /// pane that never ran one, and for an instance that cannot know.
  int? get exitCode => null;

  /// Non-blank lines this shell printed **before the user ran anything in it** —
  /// its banner, MOTD and first prompt. Null until the user submits a line;
  /// `shouldDetachOnClose` uses it to tell a greeting from real history.
  int? get greetingLines => null;

  /// Drives selection/scroll for the view — read to copy the current selection.
  TerminalController get controller;

  /// Owned by the instance rather than the widget so the app can focus a pane
  /// and scroll it to a search hit without reaching into the widget tree.
  FocusNode get focusNode;
  ScrollController get scrollController;

  /// OSC 133 command boundaries, or `null` when the shell was not integrated.
  /// Null rather than an empty tracker, so the UI can tell the two apart.
  CommandBlockRecorder? get commandBlocks;

  /// Tears down the backing process/streams. Safe to call more than once.
  void dispose();
}

/// A [TerminalInstance] whose teardown outlives its `dispose()` — which stays
/// synchronous, so dropping this future on quit orphaned the pane's process.
abstract interface class ReapableTerminalInstance {
  /// Completes once the process tree behind this pane is gone. Already complete
  /// before [TerminalInstance.dispose] is called, so awaiting it is always safe.
  Future<void> get reaped;
}

/// A [TerminalInstance] holding a pseudoconsole of its own. Releasing it is
/// worth doing while the app runs and worth nothing when the process is ending.
abstract interface class PseudoConsoleOwner {
  /// Leave the pseudoconsole to the OS when this pane is disposed. One-way, and
  /// per pane: set by the shutdown that is about to end the process.
  void keepPseudoConsoleOnDispose();
}

/// A [TerminalInstance] whose output ingestion answers to how visible it is.
/// The controller sets the tier from the layout; a pane never chooses its own.
abstract interface class TieredTerminalInstance {
  /// How visible this pane is now.
  void setIngestTier(IngestTier tier);

  /// What it was last told.
  IngestTier get ingestTier;
}

/// A [TerminalInstance] that gives its scrollback back while it is cold: the
/// history lives here as encoded text, and the controller stores it verbatim.
abstract interface class ParkableTerminalInstance {
  /// The encoded window held in place of a parsed buffer, or `null` when this
  /// pane's scrollback is live.
  String? get parkedScrollback;
}

/// A [TerminalInstance] whose parsed buffer can be handed to its replacement,
/// saving a 10-25 ms codec round trip. `null` when the history is only text.
abstract interface class AdoptableTerminalInstance {
  /// The buffer holding this pane's history, or `null` when there is none to
  /// hand over.
  Terminal? get adoptableBuffer;
}

/// A [TerminalInstance] whose output can be taped. The tap is upstream of the
/// ingest tier: a cold pane's bytes never reach `terminal.write` at all.
abstract interface class RecordableTerminalInstance {
  /// Starts copying this pane's output into [recorder]. Replaces any recorder
  /// already attached.
  void startRecording(CastRecorder recorder);

  /// Stops copying. The recorder keeps what it has.
  void stopRecording();

  /// The recorder taping this pane, or null.
  CastRecorder? get recorder;
}

/// A [ValueListenable] that holds one value and never notifies — what
/// [TerminalInstance.directory] is for a pane whose shell cannot report one.
class UnchangingValue<T> implements ValueListenable<T> {
  const UnchangingValue(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// A pane's working directory: where it launched, then whatever OSC 7 says. A
/// [ValueNotifier], so a shell re-emitting the same path costs nothing.
class WorkingDirectoryTracker {
  WorkingDirectoryTracker(String? launchedIn, {String? hostname})
    : _hostname = hostname ?? localHostname,
      _directory = ValueNotifier(launchedIn);

  /// This machine's name, read once. Null when the host will not say, which
  /// makes every named host foreign — see [workingDirectoryFromOsc].
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

  /// One OSC from the pane's [OscRouter]. `null` from the parser means *no
  /// answer*, never *the pane has no directory*.
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
/// [Terminal] — the one deliberate exception to the `CommandRunner` rule.
class PtyTerminalInstance
    implements
        TerminalInstance,
        ReapableTerminalInstance,
        PseudoConsoleOwner,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance,
        RecordableTerminalInstance {
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
    // Handlers are set on an adopted buffer as well as a fresh one: they are
    // the same values, and a branch here is a branch that can drift.
    terminal = (adoptTerminal ?? Terminal(maxLines: kLiveScrollbackMaxLines))
      // `KarmashalaInputHandler` is ours: the package encodes every modified
      // Enter as a bare CR, so Shift+Enter is indistinguishable from submit.
      ..inputHandler = const KarmashalaInputHandler()
      // The pane owns xterm's single OSC slot for its whole life and fans it
      // out: OSC 133 blocks need integration on, OSC 7 must work either way.
      ..onPrivateOSC = _osc.dispatch
      // xterm2 consumes OSC 7 itself, so the directory arrives here instead,
      // re-shaped into the pair the router carries. (`OSC 9 ; 9` lands here too
      // with a bare path, which `workingDirectoryFromOsc` declines.)
      ..onCurrentDirectoryChange = (uri) => _osc.dispatch('7', [uri]);
    // Registered before the process starts, so no sequence can be missed. The
    // directory listens unconditionally: many shells emit OSC 7 unaided.
    _osc.add(_cwd.handleOsc);
    if (shellIntegration) {
      commandBlocks = CommandBlockRecorder(terminal)..attach(_osc);
    }
    // Replay the previous session's scrollback *before* the shell starts, so
    // restored history sits above the new process's first output. An adopted
    // buffer is that history already and needs only the marker.
    if (adoptTerminal == null) {
      writeRestoredScrollback(terminal, restoredScrollback);
    } else {
      writeRestoreMarker(terminal);
    }
    // flutter_pty forwards only a tiny env allowlist; pass the host environment
    // so Windows shells get SystemRoot/WINDIR (without them powershell.exe and
    // wsl.exe fail to start), sanitized against a POSIX env leaked from WSL.
    final startIn =
        (launch.workingDirectory != null &&
            Directory(launch.workingDirectory!).existsSync())
        ? launch.workingDirectory
        : null;
    // An exact-argv launch is quoted for flutter_pty's unquoted Windows
    // concatenation here, and its executable is not repeated.
    final start = flutterPtyStartFor(launch, hostIsWindows: Platform.isWindows);
    _pty = Pty.start(
      launch.executable,
      arguments: start.arguments,
      environment: _ptyEnvironment(launch.environment),
      workingDirectory: startIn,
      repeatExecutableOnWindows: start.repeatExecutable,
    );

    // Buffer the raw PTY bytes and hand them to the terminal once per frame:
    // flutter_pty reads 1 KB at a time, so a busy shell otherwise costs hundreds
    // of decodes, parses and notifyListeners() a second on the UI isolate.
    _coalescer = PtyOutputCoalescer(
      onData: terminal.write,
      budget: ingestBudget,
    );
    _cold = ColdIngest(terminal: terminal, budget: ingestBudget);
    _outputSubscription = _pty.output.listen(_onPtyBytes);

    // Captured while the process is certainly alive: the OS can recycle a pid.
    _pid = _pty.pid;

    unawaited(
      _pty.exitCode.then(
        (code) {
          _exited = true;
          _exitCode = code;
          if (_disposed) return;
          _emit('\r\n\x1b[90m[process exited with code $code]\x1b[0m\r\n');
          // The buffer stays, but the pane is no longer a terminal you can type
          // into — say so, so the UI can stop drawing it as one.
          _liveness.value = PaneLiveness.exited;
        },
        // A wait that failed is still an ending; the code is genuinely unknown.
        onError: (Object error) {
          _exited = true;
          if (_disposed) return;
          _emit(
            '\r\n\x1b[90m[process ended; exit code unknown ($error)]\x1b[0m\r\n',
          );
          _liveness.value = PaneLiveness.exited;
        },
      ),
    );

    terminal.onOutput = (data) {
      if (_disposed) return;
      _recordGreeting(data);
      try {
        _pty.write(const Utf8Encoder().convert(data));
      } catch (_) {
        // The PTY has gone away — ignore late keystrokes.
      }
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_disposed) return;
      _recorder?.addResize(width, height);
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

  /// Seeded with the launch directory, then kept current by the shell's OSC 7.
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

  int? _greetingLines;

  @override
  int? get greetingLines => _greetingLines;

  /// Records the greeting the first time the user **submits a line** — keyed on
  /// a carriage return, because the terminal answers ~8 ms in on its own.
  void _recordGreeting(String data) {
    if (_greetingLines != null || !data.contains('\r')) return;
    _greetingLines = nonBlankLineCount(terminal);
  }

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
  /// is the history: not while running, parked, or on the alternate buffer.
  @override
  Terminal? get adoptableBuffer =>
      _exited && !_cold.isParked && !terminal.isUsingAltBuffer
      ? terminal
      : null;

  /// Bytes this pane is holding for a replay. Diagnostics, and what the
  /// ingest-tier tests assert on.
  @visibleForTesting
  int get spooledBytes => _cold.spooledBytes;

  /// Reads the pipe. A pane nobody can see sends its bytes to [ColdIngest]
  /// undecoded, but something must still read, or the child blocks on a full
  /// OS buffer.
  void _onPtyBytes(Uint8List bytes) {
    if (_disposed) return;
    // Before the tier split, so a recording keeps running while the pane is cold.
    _recorder?.addOutput(bytes);
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
      // Hand over what is already queued rather than parsing it on the way out.
      if (_cold.detach(_coalescer.takePending())) {
        // The blocks whose prompt line just went are what held those lines
        // alive through their anchors; dropping them releases the memory.
        commandBlocks?.tracker.pruneEvicted();
      }
    } else if (wasCold) {
      _cold.reattach();
    }
  }

  /// Writes text the app generated wherever this pane's output is going — the
  /// buffer while it is visible, and [ColdIngest] while it is not.
  void _emit(String text) {
    _recorder?.addText(text);
    if (_tier == IngestTier.cold) {
      _cold.emit(text);
      return;
    }
    terminal.write(text);
  }

  @override
  Future<void> get reaped => _reap ?? Future<void>.value();

  CastRecorder? _recorder;

  @override
  CastRecorder? get recorder => _recorder;

  @override
  void startRecording(CastRecorder recorder) => _recorder = recorder;

  @override
  void stopRecording() => _recorder = null;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Tell the recording its subject has gone before anything else can fail.
    _recorder?.sourceEnded();
    _recorder = null;
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
    // Ask the process to exit before destroying it, so a build or ssh session
    // can flush. Quitting waits for it; the pty is released after the reap.
    _reap =
        closePaneProcess(
          kill: _pty.kill,
          exitCode: _pty.exitCode,
          // The whole tree, not just the pid: see killWindowsProcessTree.
          pid: _exited ? null : _pid,
          // Read at the end, not now: the quit can arrive while this reap is still
          // in flight, and it is the quit's answer that decides.
          keepPseudoConsole: () => _keepPseudoConsole,
          releasePseudoConsole: _pty.destroy,
        ).then((report) {
          // What a pane close actually did: the 2026-09-10 hang turned on whether
          // the tree was gone when the console was released.
          _log.info('pane $id: ${report.summary}.');
        });
  }

  static final _log = AppLogger.named('terminal.pane');

  /// Set by the shutdown that is about to end this process. See
  /// [PseudoConsoleOwner].
  bool _keepPseudoConsole = false;

  @override
  void keepPseudoConsoleOnDispose() => _keepPseudoConsole = true;
}

/// Writes [scrollback] into [terminal] followed by a dim marker, so replayed
/// history is visibly separate. Does nothing when there is nothing to restore.
void writeRestoredScrollback(Terminal terminal, String? scrollback) {
  if (scrollback == null || scrollback.isEmpty) return;
  terminal.write(scrollback);
  writeRestoreMarker(terminal);
}

/// Writes the dim marker that says where replayed history ends and the live
/// process begins. Its own function because an adopted buffer needs only this.
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

/// Builds the environment for a Windows PTY child: the host's, minus the POSIX
/// `PATH`/`SHELL`/`WSL*` that leak from a WSL launch and break `wsl.exe`.
Map<String, String> _ptyEnvironment([Map<String, String> extra = const {}]) {
  final env = Map<String, String>.of(Platform.environment);

  // WSL-interop / Unix-shell leaks; harmless no-ops on a clean launch.
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

  // Layered last so a caller's variables survive the scrubbing above — an agent
  // pane sets WSLENV deliberately, and it must not be the one just removed.
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
    // A failed *restart* still holds the history of the pane it replaced, and
    // that history is the reason anyone would retry.
    terminal =
        adoptTerminal ?? Terminal(maxLines: kErrorPaneScrollbackMaxLines);
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

  // Nothing ever ran here, so there is no greeting to have measured.
  @override
  int? get greetingLines => null;

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

/// The grid the app last laid a restored pane out at, shared by all of them —
/// without it a pane parses at 80 columns and is reflowed in the same frame.
class TerminalGridHint {
  /// Null until the workbench has laid a restored pane out.
  ({int columns, int rows})? grid;
}

/// A [TerminalInstance] rebuilt from a stored record with **no process behind
/// it**: starting one would re-execute the launch command it recorded.
class DormantTerminalInstance
    implements TerminalInstance, AdoptableTerminalInstance {
  DormantTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required this.restoredScrollback,
    this.workingDirectory,
    this.agentLaunch,
    this.wasLive = false,
    this.gridHint,
  });

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;

  /// Whether this pane had a process behind it when the app last closed — kept
  /// so a tab opened later can start what was running in it.
  final bool wasLive;

  /// Replayed history with nothing running behind it: the directory it holds is
  /// the one the pane was last observed in, and nothing here can move it.
  @override
  late final ValueListenable<String?> directory = UnchangingValue(
    workingDirectory,
  );

  @override
  final AgentPaneLaunch? agentLaunch;

  /// The stored scrollback exactly as it was read back, so starting the pane
  /// replays precisely that — no second codec round trip, no duplicate marker.
  final String restoredScrollback;

  /// Where this pane reads — and reports — the size to parse at. Read at parse
  /// time, not construction: every pane is built before the layout exists.
  final TerminalGridHint? gridHint;

  /// Parsed only when something asks to see it: a restored layout can hold a
  /// hundred panes, most of which are never opened and never built at all.
  @override
  late final Terminal terminal = _buildTerminal();

  /// Whether anything has asked to see this pane yet — `late final` cannot be
  /// asked whether it has run.
  @visibleForTesting
  bool get bufferBuilt => _bufferBuilt;
  bool _bufferBuilt = false;

  /// The buffer, but only once something has already built it: building one to
  /// hand over would *be* the parse this exists to avoid.
  @override
  Terminal? get adoptableBuffer =>
      _bufferBuilt && restoredScrollback.isNotEmpty ? terminal : null;

  Terminal _buildTerminal() {
    _bufferBuilt = true;
    final built = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..inputHandler = const KarmashalaInputHandler();
    final hint = gridHint;
    if (hint != null) {
      // Before the write, or the hint buys nothing: it is the *parse* that has
      // to happen at the width the text will be read at.
      if (hint.grid case (:final columns, :final rows)?) {
        built.resize(columns, rows);
      }
      // Nothing else claims `onResize` here, so this pane can report what the
      // workbench laid it out at, for the next one to parse into.
      built.onResize = (columns, rows, _, _) =>
          hint.grid = (columns: columns, rows: rows);
    }
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

  // Nothing ever ran here, so there is no greeting to have measured.
  @override
  int? get greetingLines => null;

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

/// Whether a pane launched this way gets an OSC 133 [CommandBlockRecorder]: no
/// agent pane (it runs the CLI directly, so there is no prompt hook), the
/// user's setting on, and a shell that can emit markers — never `cmd.exe`.
bool shellIntegrationApplies({
  required TerminalProfile profile,
  required bool shellIntegration,
  required AgentPaneLaunch? agentLaunch,
}) =>
    agentLaunch == null &&
    shellIntegration &&
    shellSupportsIntegration(profile.shell);

/// The production [TerminalInstanceFactory]: spawns a [PtyTerminalInstance],
/// degrading to an [ErrorTerminalInstance] whose buffer shows the failure.
TerminalInstance createPtyTerminalInstance({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
  Map<String, String> environmentOverlay = const {},
}) {
  // An agent pane runs the agent CLI itself, so the shell profile is not
  // consulted and shell integration is meaningless: OSC 133 comes from a shell.
  final PtyLaunch launch;
  final String title;
  final String profileId;
  final integrate = shellIntegrationApplies(
    profile: profile,
    shellIntegration: shellIntegration,
    agentLaunch: agentLaunch,
  );
  if (agentLaunch != null) {
    // The one place `Platform.isWindows` becomes a launch context: from here
    // down the command is built for where it is going, not for where we are.
    launch = agentPtyLaunchFor(
      agentLaunch,
      context: LaunchContext.forAgent(
        agentLaunch,
        hostIsWindows: Platform.isWindows,
      ),
      environment: environmentOverlay,
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
      environment: environmentOverlay,
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
const int _maxArgumentInMessage = 120;

/// [arguments] as one line, with anything unreadably long summarised: a
/// shell-integrated PowerShell pane's `-Command` script runs to thousands of
/// characters and pushed the exception that explains the failure off screen.
String describeLaunchArguments(List<String> arguments) => [
  for (final argument in arguments)
    if (argument.length <= _maxArgumentInMessage)
      argument
    else
      '<${argument.length} characters elided>',
].join(' ');
