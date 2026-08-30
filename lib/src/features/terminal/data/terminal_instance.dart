import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../domain/mouse_wheel_reporter.dart';
import '../domain/pane_liveness.dart';
import '../domain/scrollback_limits.dart';
import '../domain/terminal_profile.dart';
import 'command_block_recorder.dart';
import 'process_shutdown.dart';
import 'pty_launch.dart';
import 'pty_output_coalescer.dart';

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

  /// Whether a process is running behind [terminal], and why not when there is
  /// none. Listenable so a pane stops advertising itself as live the moment its
  /// process exits, without the controller polling for it.
  ValueListenable<PaneLiveness> get liveness;

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

/// Signature for creating a [TerminalInstance] — injected so tests can supply a
/// process-free fake (a real [Pty] would try to spawn a shell).
typedef TerminalInstanceFactory =
    TerminalInstance Function({
      required String id,
      required TerminalProfile profile,
      String? workingDirectory,
      String? restoredScrollback,
      bool shellIntegration,
    });

/// A [TerminalInstance] backed by a real host ConPTY ([Pty]) wired to an xterm
/// [Terminal]: PTY output is decoded into the buffer, keystrokes are encoded
/// back to the PTY, and terminal resizes are forwarded.
///
/// This is the one deliberate exception to the `CommandRunner` rule
/// (architecture constraint 6): an interactive terminal needs a pseudo-terminal,
/// which the run-to-completion/stream abstraction does not model.
class PtyTerminalInstance implements TerminalInstance {
  PtyTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required PtyLaunch launch,
    this.workingDirectory,
    String? restoredScrollback,
    bool shellIntegration = false,
  }) {
    terminal = Terminal(maxLines: kLiveScrollbackMaxLines)
      // xterm 4.0.0 reports the wheel with the wrong button ids, which stops
      // tmux (and anything else reading the modifier bits) from scrolling.
      ..mouseHandler = const ChitraguptaMouseHandler();
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
      environment: _ptyEnvironment(),
      workingDirectory: workingDirectory,
    );

    // Buffer the raw PTY bytes and hand them to the terminal once per frame.
    // flutter_pty reads 1 KB at a time, so without this a busy shell costs
    // hundreds of decodes, parses and notifyListeners() a second on the UI
    // isolate — which is what the streaming stutter was.
    _coalescer = PtyOutputCoalescer(onData: terminal.write);
    _outputSubscription = _pty.output.listen(_coalescer.add);

    // Captured while the process is certainly alive: `pid` is only safe to act
    // on before the OS can recycle the number.
    _pid = _pty.pid;

    _pty.exitCode.then((code) {
      _exited = true;
      if (_disposed) return;
      terminal.write('\r\n\x1b[90m[process exited with code $code]\x1b[0m\r\n');
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
  final _liveness = ValueNotifier(PaneLiveness.live);

  late final Pty _pty;
  late final PtyOutputCoalescer _coalescer;
  late final StreamSubscription<Uint8List> _outputSubscription;
  late final int _pid;
  bool _disposed = false;
  bool _exited = false;

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
    unawaited(
      shutdownProcess(
        kill: _pty.kill,
        exitCode: _pty.exitCode,
        // The whole tree, not just the pid: see killWindowsProcessTree.
        pid: _exited ? null : _pid,
      ),
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
Map<String, String> _ptyEnvironment() {
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
  }) {
    terminal = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..mouseHandler = const ChitraguptaMouseHandler();
    if (restoredScrollback.isNotEmpty) terminal.write(restoredScrollback);
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;

  /// The stored scrollback exactly as it was read back.
  ///
  /// Kept as the original string rather than re-encoded from [terminal] so that
  /// starting the pane replays precisely what was restored, with no second
  /// round-trip through the codec and no duplicated restore marker.
  final String restoredScrollback;

  @override
  late final Terminal terminal;
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

/// The production [TerminalInstanceFactory]: builds a [PtyLaunch] for the profile
/// and spawns a [PtyTerminalInstance], degrading to an [ErrorTerminalInstance]
/// (whose buffer shows the failure) if the PTY cannot be created.
TerminalInstance createPtyTerminalInstance({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
}) {
  // The terminal profiles (PowerShell/cmd/WSL) assume a Windows host. When the
  // app itself runs on Linux/macOS (e.g. inside WSL), `wsl.exe`/`powershell.exe`
  // don't exist — we're already in the target shell — so just open the login
  // shell in the working directory.
  final PtyLaunch launch;
  if (Platform.isWindows) {
    launch = ptyLaunchFor(
      profile,
      workingDirectory: workingDirectory,
      shellIntegration: shellIntegration,
    );
  } else {
    final shell = Platform.environment['SHELL'] ?? '/bin/bash';
    launch = PtyLaunch(executable: shell, workingDirectory: workingDirectory);
  }
  try {
    return PtyTerminalInstance(
      id: id,
      title: profile.label,
      profileId: profile.id,
      launch: launch,
      workingDirectory: workingDirectory,
      restoredScrollback: restoredScrollback,
      shellIntegration: shellIntegration && Platform.isWindows,
    );
  } catch (e) {
    final args = launch.arguments.join(' ');
    return ErrorTerminalInstance(
      id: id,
      title: profile.label,
      profileId: profile.id,
      workingDirectory: workingDirectory,
      restoredScrollback: restoredScrollback,
      message:
          'Failed to start "${launch.executable} $args"'
          '${launch.workingDirectory == null ? '' : ' in ${launch.workingDirectory}'}: $e',
    );
  }
}
