import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import '../../../core/logging/app_logger.dart';
import '../../ssh/data/host_session_access.dart';
import '../../ssh/domain/host_deployment.dart';
import '../../ssh/domain/ssh_host.dart';
import '../../ssh/data/ssh_connection.dart';
import '../domain/agent_pane_launch.dart';
import '../domain/enter_key_encoding.dart';
import '../domain/ingest_tier.dart';
import '../domain/osc_router.dart';
import '../domain/pane_liveness.dart';
import '../domain/scrollback_limits.dart';
import 'cast_recorder.dart';
import 'cold_screen.dart';
import 'host_pane_link.dart';
import 'command_block_recorder.dart';
import 'pty_output_coalescer.dart';
import 'terminal_grid_text.dart';
import 'terminal_ingest_budget.dart';
import 'terminal_instance.dart';

/// A [TerminalInstance] backed by a remote interactive session over SSH.
///
/// Two paths, and which one is used is a *measurement* — [hostDeployment],
/// taken by [HostDeployer] with the time it was taken — not a setting:
///
///  * **The session host.** When a `karmashala_host` is deployed and answering
///    on the machine, the pane runs `karmashala_host attach` on an exec channel
///    and speaks the host protocol. The child's bytes arrive untouched, so
///    OSC 133 marks, OSC 8 links, OSC 777, kitty sequences and alternate-screen
///    content survive; sessions outlive the pane, the connection and the app.
///  * **tmux**, the fallback, unchanged. tmux is itself a terminal emulator, so
///    on the ordinary attach path the renderer gets tmux's *redraw* of the agent
///    rather than the agent's bytes and every signal above is lost. It is still
///    the right answer where the host cannot run — musl, macOS, a read-only or
///    noexec home, an older host still serving — and the pane says which one it
///    got rather than leaving the difference invisible.
class SshTerminalInstance
    implements
        TerminalInstance,
        ReapableTerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance,
        RecordableTerminalInstance {
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
    this.hostAccess,
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
      final link = _link;
      if (link != null) {
        link.write(Uint8List.fromList(utf8.encode(data)));
        return;
      }
      final session = _session;
      if (session != null) {
        try {
          session.write(Uint8List.fromList(utf8.encode(data)));
        } catch (_) {}
      }
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_disposed) return;
      _recorder?.addResize(width, height);
      final link = _link;
      if (link != null) {
        link.resize(width, height);
        return;
      }
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

  /// This machine's session host: the reading, the channel, and the event that
  /// says the connection came back. Null means nobody has looked, which is not
  /// the same as a negative answer — the pane takes the tmux path without
  /// claiming the host is unavailable.
  ///
  /// It is a [HostSessionAccess] rather than an SSH type so the local stage can
  /// supply a socket-backed one without touching this class.
  final HostSessionAccess? hostAccess;

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
  HostPaneLink? _link;
  StreamSubscription<Uint8List>? _hostOutput;
  StreamSubscription<String>? _hostNotices;
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

  CastRecorder? _recorder;

  @override
  CastRecorder? get recorder => _recorder;

  @override
  void startRecording(CastRecorder recorder) => _recorder = recorder;

  @override
  void stopRecording() => _recorder = null;

  void _onDataBytes(List<int> bytes) {
    if (_disposed) return;
    final uint8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    // Before the tier split — see [RecordableTerminalInstance].
    _recorder?.addOutput(uint8);
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
    _recorder?.addText(text);
    if (_tier == IngestTier.cold) {
      _cold.emit(text);
      return;
    }
    terminal.write(text);
  }

  Future<void> _connectAndStart() async {
    _emit('\x1b[90mConnecting to ${host.name} (${host.address})...\x1b[0m\r\n');
    if (await _startViaHost()) return;
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

  /// Runs the pane against the session host, or returns false and lets the
  /// tmux path take over.
  ///
  /// Every way of returning false says why in the pane first. A silent fallback
  /// would leave a user wondering why their command blocks stopped working, and
  /// the answer — "this host runs musl" — is one they can act on.
  Future<bool> _startViaHost() async {
    final access = hostAccess;
    if (access == null) return false;
    final HostDeployment deployment;
    try {
      deployment = await access.deployment();
    } on Object catch (e) {
      _emit(
        '\x1b[33m[could not ask ${host.address} about its session host ($e). '
        'Falling back to tmux.]\x1b[0m\r\n',
      );
      return false;
    }
    if (_disposed) return true;
    if (deployment.fallsBackToTmux) {
      _emit(
        '\x1b[33m[session host unavailable: ${deployment.reason} '
        'Falling back to tmux, which does not carry command blocks, links or '
        'exit codes.]\x1b[0m\r\n',
      );
      return false;
    }
    final remotePath = deployment.remotePath;
    if (remotePath == null) return false;

    // A host we had to start ourselves is a host that was not running: after a
    // reboot, or after somebody killed it. Its sessions are gone and saying so
    // is the honest version of having no supervisor.
    if (deployment.restartedByUs) {
      _emit(
        '\x1b[33m[the session host on ${host.address} was not running and has '
        'been restarted; any sessions it held before are gone]\x1b[0m\r\n',
      );
    }

    if (!await _dialHost(access, deployment, remotePath)) return false;

    // Re-dial on the pool re-establishing the connection, not on a timer: the
    // app already observes that transition and a poll would be a second,
    // slower, wronger answer to a question already answered.
    _reconnects ??= access.reconnected.listen((_) => unawaited(_reconnectToHost(access)));
    return true;
  }

  StreamSubscription<void>? _reconnects;

  /// Opens a link and attaches this pane's session to it. Returns false when
  /// the host would not have us, having said why.
  Future<bool> _dialHost(
    HostSessionAccess access,
    HostDeployment deployment,
    String remotePath,
  ) async {
    final width = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
    final height = terminal.viewHeight > 0 ? terminal.viewHeight : 24;
    // Read before the new link exists: a fresh link's own offset is zero, and
    // asking it where to resume from would replay the session from the start.
    final resumeFrom = _lastHostOffset;
    try {
      final link = await HostPaneLink.open(
        await access.exec('$remotePath attach'),
        clientId: 'pane-$id',
      );
      if (_disposed) {
        await link.close();
        return true;
      }
      _link = link;

      // The session id is the pane's own, stable across reattach, so the same
      // pane always finds the same session. `attach` first: on a reconnect the
      // session is already there and asking to open it would be refused.
      final attachment = await _attachOrOpen(link, width, height, resumeFrom);
      _emit(
        '\x1b[90m[session host ${deployment.hostVersion ?? 'unknown'} on '
        '${host.address}: ${attachment.sessionId}, '
        '${attachment.totalBytes} bytes so far]\x1b[0m\r\n',
      );

      _hostOutput = link.output.listen(_onDataBytes, onDone: _onHostChannelClosed);
      _hostNotices = link.notices.listen(
        (notice) => _emit('\r\n\x1b[33m[$notice]\x1b[0m\r\n'),
      );
      unawaited(link.ended.then(_onHostSessionEnded));
      return true;
    } on Object catch (e) {
      _link = null;
      _logger.error('Session host on ${host.address} refused a pane: $e');
      _emit(
        '\x1b[33m[the session host on ${host.address} could not start this pane '
        '($e). Falling back to tmux.]\x1b[0m\r\n',
      );
      return false;
    }
  }

  /// The connection came back. Attach from the last offset this pane rendered,
  /// so the gap is filled exactly once and nothing is shown twice.
  Future<void> _reconnectToHost(HostSessionAccess access) async {
    if (_disposed || _exited || _link != null) return;
    final resumeFrom = _lastHostOffset;
    _emit(
      '\x1b[90m[reconnected to ${host.address}; resuming from byte '
      '$resumeFrom]\x1b[0m\r\n',
    );
    final HostDeployment deployment;
    try {
      deployment = await access.deployment();
    } on Object catch (e) {
      _emit('\r\n\x1b[33m[the session host on ${host.address} is not answering ($e)]\x1b[0m\r\n');
      return;
    }
    final remotePath = deployment.remotePath;
    if (_disposed || deployment.fallsBackToTmux || remotePath == null) {
      _emit(
        '\r\n\x1b[33m[the session host is no longer available: '
        '${deployment.reason}]\x1b[0m\r\n',
      );
      return;
    }
    if (deployment.restartedByUs) {
      _emit(
        '\r\n\x1b[33m[the session host on ${host.address} was restarted while this '
        'pane was away; its earlier sessions are gone]\x1b[0m\r\n',
      );
    }
    await _hostOutput?.cancel();
    await _hostNotices?.cancel();
    await _dialHost(access, deployment, remotePath);
  }

  /// Reattach from the last offset this pane rendered; open only when there is
  /// no such session yet.
  Future<HostAttachment> _attachOrOpen(
    HostPaneLink link,
    int width,
    int height,
    int sinceOffset,
  ) async {
    final sessionId = _hostSessionId();
    try {
      return await link.attachSession(sessionId: sessionId, sinceOffset: sinceOffset);
    } on HostLinkException {
      // No such session: this is the pane's first run on this host.
      final launch = agentLaunch;
      return link.openSession(
        sessionId: sessionId,
        argv: launch == null
            ? const ['/bin/sh', '-l']
            : [launch.executable, ...launch.commandArguments],
        workingDirectory: workingDirectory,
        environment: const {'TERM': 'xterm-256color'},
        columns: width,
        rows: height,
      );
    }
  }

  /// The app's own id, not one the host invents: the same pane must find the
  /// same session after a reconnect, and an agent must keep its session across
  /// pane replacement — the same rule the tmux session name follows.
  String _hostSessionId() {
    final raw = agentLaunch?.sessionId != null
        ? 'karmashala_${agentLaunch!.sessionId}'
        : 'karmashala_${host.id}_$id';
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  /// What the pane has actually rendered, carried across a link being replaced
  /// so a reconnect neither repeats a byte nor drops one. Updated from the link
  /// whenever one goes away.
  int _lastHostOffset = 0;

  void _onHostChannelClosed() {
    _lastHostOffset = _link?.lastOffset ?? _lastHostOffset;
    // Dropped, not closed: the pane keeps the offset and waits for the pool's
    // reconnect event to dial again.
    _link = null;
    if (_disposed || _exited) return;
    // The link went away, not the session. Saying so is the difference between
    // this and the pane simply dying.
    _emit(
      '\r\n\x1b[33m[the connection to the session host dropped. The session is '
      'still running there; reopening this pane resumes it from byte '
      '$_lastHostOffset.]\x1b[0m\r\n',
    );
    // Deliberately still `live`: a process *is* running behind this buffer,
    // which is what PaneLiveness documents, and calling it `exited` would be
    // the false statement — the session is exactly what survived. What is
    // temporarily untrue is that keystrokes reach it, and the notice above says
    // so. A `disconnected` state would be the honest third answer; ten files
    // switch on this enum and adding one belongs in its own change.
  }

  void _onHostSessionEnded(HostSessionEnd end) {
    _exited = true;
    if (_disposed) return;
    _exitCode = end.exitCode;
    _emit(
      end.exitCode == null
          // Never a zero: a code the host could not collect is not a success.
          ? '\r\n\x1b[90m[remote process ended; exit code unknown '
                '(${end.reason})]\x1b[0m\r\n'
          : '\r\n\x1b[90m[remote process exited with code ${end.exitCode}]\x1b[0m\r\n',
    );
    _liveness.value = PaneLiveness.exited;
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
    // A pane closed mid-recording hands over what it captured — see
    // [RecordableTerminalInstance].
    _recorder?.sourceEnded();
    _recorder = null;
    _liveness.value = PaneLiveness.exited;
    _liveness.dispose();
    _cwd.dispose();

    unawaited(_reconnects?.cancel());
    unawaited(_hostOutput?.cancel());
    unawaited(_hostNotices?.cancel());
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    _coalescer.dispose();
    focusNode.dispose();
    scrollController.dispose();

    final link = _link;
    if (link != null) {
      _link = null;
      final reap = Completer<void>();
      _reap = reap;
      // Closing the link is a *disconnect*, never a kill: the host frees the
      // write token and the session keeps running for the next pane.
      unawaited(link.close().whenComplete(() {
        if (!reap.isCompleted) reap.complete();
      }));
      return;
    }

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
