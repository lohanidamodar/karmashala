import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import '../../../core/logging/app_logger.dart';
import '../../ssh/data/ssh_connection.dart';
import '../../ssh/domain/ssh_host.dart';
import '../domain/agent_pane_launch.dart';
import '../domain/enter_key_encoding.dart';
import '../domain/ingest_tier.dart';
import '../domain/osc_router.dart';
import '../domain/pane_liveness.dart';
import '../domain/scrollback_limits.dart';
import 'cold_screen.dart';
import 'command_block_recorder.dart';
import 'pty_output_coalescer.dart';
import 'terminal_grid_text.dart';
import 'terminal_ingest_budget.dart';
import 'terminal_instance.dart';

/// A [TerminalInstance] backed by a remote interactive session over SSH.
///
/// If `tmux` is available on the remote host, the session is started inside
/// a tmux session. When the terminal is closed locally (or the SSH connection
/// drops), the tmux session detaches and stays running remotely. Re-opening
/// the session attaches back to the running tmux session.
class SshTerminalInstance
    implements
        TerminalInstance,
        ReapableTerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance {
  SshTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required this.host,
    required this.connection,
    String? workingDirectory,
    this.agentLaunch,
    this.adoptTerminal,
    String? restoredScrollback,
    TerminalIngestBudget? ingestBudget,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('terminal.ssh'),
       _cwd = WorkingDirectoryTracker(workingDirectory, hostname: host.host) {
    terminal = adoptTerminal ?? Terminal(maxLines: kLiveScrollbackMaxLines)
      ..inputHandler = const KarmashalaInputHandler()
      ..onPrivateOSC = _osc.dispatch
      ..onCurrentDirectoryChange = (uri) => _osc.dispatch('7', [uri]);

    _osc.add(_cwd.handleOsc);

    if (adoptTerminal == null) {
      writeRestoredScrollback(terminal, restoredScrollback);
    } else {
      writeRestoreMarker(terminal);
    }

    _coalescer = PtyOutputCoalescer(
      onData: terminal.write,
      budget: ingestBudget,
    );
    _cold = ColdIngest(terminal: terminal, budget: ingestBudget);

    terminal.onOutput = (data) {
      if (_disposed) return;
      _recordGreeting(data);
      final session = _session;
      if (session != null) {
        try {
          session.write(Uint8List.fromList(utf8.encode(data)));
        } catch (_) {}
      }
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_disposed) return;
      final session = _session;
      if (session != null) {
        try {
          session.resizeTerminal(width, height);
        } catch (_) {}
      }
    };

    unawaited(_connectAndStart());
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  final SshHost host;
  final SshConnection connection;

  final AppLogger _logger;
  final WorkingDirectoryTracker _cwd;
  final OscRouter _osc = OscRouter();

  @override
  String? get workingDirectory => _cwd.value;

  @override
  ValueListenable<String?> get directory => _cwd.listenable;

  @override
  final AgentPaneLaunch? agentLaunch;
  final Terminal? adoptTerminal;

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

  final ValueNotifier<PaneLiveness> _liveness = ValueNotifier(
    PaneLiveness.live,
  );

  @override
  ValueListenable<PaneLiveness> get liveness => _liveness;

  int? _exitCode;
  @override
  int? get exitCode => _exitCode;

  int? _greetingLines;
  @override
  int? get greetingLines => _greetingLines;

  late final PtyOutputCoalescer _coalescer;
  late final ColdIngest _cold;
  IngestTier _tier = IngestTier.hot;

  SSHSession? _session;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;
  bool _disposed = false;
  bool _exited = false;
  Completer<void>? _reap;

  @override
  Future<void> get reaped => _reap?.future ?? Future<void>.value();

  void _recordGreeting(String submitted) {
    if (_greetingLines != null || !submitted.contains('\r')) return;
    _greetingLines = nonBlankLineCount(terminal);
  }

  @override
  IngestTier get ingestTier => _tier;

  @override
  String? get parkedScrollback => _cold.parkedScrollback;

  @override
  Terminal? get adoptableBuffer =>
      _exited && !_cold.isParked && !terminal.isUsingAltBuffer ? terminal : null;

  void _onDataBytes(List<int> bytes) {
    if (_disposed) return;
    final uint8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (_tier == IngestTier.cold) {
      _cold.add(uint8);
      return;
    }
    _coalescer.add(uint8);
  }

  @override
  void setIngestTier(IngestTier tier) {
    if (_disposed || _tier == tier) return;
    final wasCold = _tier == IngestTier.cold;
    _tier = tier;
    _coalescer.tier = tier;
    if (tier == IngestTier.cold) {
      if (_cold.detach(_coalescer.takePending())) {
        commandBlocks?.tracker.pruneEvicted();
      }
    } else if (wasCold) {
      _cold.reattach();
    }
  }

  void _emit(String text) {
    if (_tier == IngestTier.cold) {
      _cold.emit(text);
      return;
    }
    terminal.write(text);
  }

  Future<void> _connectAndStart() async {
    _emit('\x1b[90mConnecting to ${host.name} (${host.address})...\x1b[0m\r\n');
    final SSHClient client;
    try {
      client = await connection.client();
    } on Object catch (e) {
      if (_disposed) return;
      _exited = true;
      _emit('\r\n\x1b[31mCould not connect to ${host.address}: $e\x1b[0m\r\n');
      _liveness.value = PaneLiveness.exited;
      return;
    }

    if (_disposed) return;

    final script = _buildRemoteScript();
    final width = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
    final height = terminal.viewHeight > 0 ? terminal.viewHeight : 24;

    try {
      final session = await client.execute(
        script,
        pty: SSHPtyConfig(
          width: width,
          height: height,
          type: 'xterm-256color',
        ),
      );

      if (_disposed) {
        session.close();
        return;
      }

      _session = session;
      _stdoutSubscription = session.stdout.listen(_onDataBytes);
      _stderrSubscription = session.stderr.listen(_onDataBytes);

      unawaited(
        session.done.then((_) {
          _exited = true;
          if (_disposed) return;
          final code = session.exitCode ?? 0;
          _exitCode = code;
          _emit('\r\n\x1b[90m[remote process exited with code $code]\x1b[0m\r\n');
          _liveness.value = PaneLiveness.exited;
        }),
      );
    } on Object catch (e) {
      if (_disposed) return;
      _exited = true;
      _logger.error('Failed to start remote session on ${host.address}: $e');
      _emit('\r\n\x1b[31mFailed to start remote session: $e\x1b[0m\r\n');
      _liveness.value = PaneLiveness.exited;
    }
  }

  /// Builds the remote shell script that detects `tmux` and either starts or
  /// reattaches to a tmux session, or falls back to standard execution.
  String _buildRemoteScript() => buildSshTerminalScript(
    paneId: id,
    hostId: host.id,
    workingDirectory: workingDirectory,
    agentLaunch: agentLaunch,
  );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _liveness.value = PaneLiveness.exited;
    _liveness.dispose();
    _cwd.dispose();

    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    _coalescer.dispose();
    focusNode.dispose();
    scrollController.dispose();

    final session = _session;
    if (session != null) {
      final reap = Completer<void>();
      _reap = reap;
      // Closing the SSH channel causes tmux to detach, keeping remote tasks running.
      try {
        session.close();
      } catch (_) {}
      session.done.whenComplete(() {
        if (!reap.isCompleted) reap.complete();
      });
    }
  }
}

/// Builds the command handed to the remote login shell.
///
/// Kept pure so quoting and tmux identity can be verified without opening a
/// socket. SSH transmits one command string, so every dynamic value must cross
/// the shell boundary through [_posixQuote].
@visibleForTesting
String buildSshTerminalScript({
  required String paneId,
  required String hostId,
  String? workingDirectory,
  AgentPaneLaunch? agentLaunch,
}) {
  final cwd = workingDirectory?.trim();
  final hasCwd = cwd != null && cwd.isNotEmpty;
  final tmuxSessionName = _sshTmuxSessionName(
    paneId: paneId,
    hostId: hostId,
    agentSessionId: agentLaunch?.sessionId,
  );
  final cdSnippet = hasCwd
      ? 'cd ${_posixQuote(cwd)} 2>/dev/null || true'
      : '';

  if (agentLaunch case final launch?) {
    final cmdParts = [launch.executable, ...launch.commandArguments];
    final rawCommand = cmdParts.map(_posixQuote).join(' ');
    final agentRunCommand = hasCwd
        ? 'cd ${_posixQuote(cwd)} && exec $rawCommand'
        : 'exec $rawCommand';

    return '''
$cdSnippet
TMUX_SESSION="$tmuxSessionName"
if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t "\$TMUX_SESSION" 2>/dev/null; then
    exec tmux attach-session -t "\$TMUX_SESSION"
  else
    exec tmux new-session -s "\$TMUX_SESSION" ${hasCwd ? '-c ${_posixQuote(cwd)}' : ''} ${_posixQuote(agentRunCommand)}
  fi
else
  $agentRunCommand
fi
''';
  }

  return '''
$cdSnippet
TMUX_SESSION="$tmuxSessionName"
if command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A -s "\$TMUX_SESSION" ${hasCwd ? '-c ${_posixQuote(cwd)}' : ''}
else
  exec "\${SHELL:-bash}" -l
fi
''';
}

String _sshTmuxSessionName({
  required String paneId,
  required String hostId,
  String? agentSessionId,
}) {
  // A session id keeps an agent attached to its remote process across local
  // pane replacement. A pane id gives each plain shell its own tmux session;
  // using only the host id made every terminal on one host share input.
  final raw = agentSessionId != null
      ? 'karmashala_$agentSessionId'
      : 'karmashala_${hostId}_$paneId';
  return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
}

String _posixQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
