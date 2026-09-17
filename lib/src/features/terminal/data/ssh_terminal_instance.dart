import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'cast_recorder.dart';
import 'cold_screen.dart';
import 'package:karmashala_host/protocol.dart' show ProtocolErrorCode;
import 'host_pane_link.dart';
import 'pane_terminal.dart';
import 'command_block_recorder.dart';
import 'pty_output_coalescer.dart';
import 'terminal_grid_text.dart';
import 'terminal_ingest_budget.dart';
import 'terminal_instance.dart';

/// What a pane prints when its remote process ends — one spelling for both
/// routes, because **a code nobody collected is unknown, never a zero** (§19).
String remoteExitNotice(int? exitCode, {String? reason}) {
  if (exitCode != null) {
    return '\r\n\x1b[90m[remote process exited with code $exitCode]\x1b[0m\r\n';
  }
  final because = reason == null || reason.isEmpty ? '' : ' ($reason)';
  return '\r\n\x1b[90m[remote process ended; exit code unknown$because]'
      '\x1b[0m\r\n';
}

/// A [TerminalInstance] backed by a remote SSH session. With the session host
/// the child's bytes arrive untouched; tmux redraws them and loses every mark.
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
    terminal = adoptTerminal ?? PaneTerminal(maxLines: kLiveScrollbackMaxLines)
      ..inputHandler = const KarmashalaInputHandler()
      ..onPrivateOSC = _osc.dispatch
      ..onCurrentDirectoryChange = (uri) => _osc.dispatch('7', [uri]);

    _osc.add(_cwd.handleOsc);

    if (adoptTerminal == null) {
      _hasStoredHistory =
          restoredScrollback != null && restoredScrollback.isNotEmpty;
      writeRestoredScrollback(terminal, restoredScrollback);
    } else {
      _hasStoredHistory = nonBlankLineCount(terminal) > 0;
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

  /// This machine's session host, or null when nobody has looked — which is not
  /// a negative answer: the pane takes the tmux path without claiming anything.
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
          // Never a zero: dartssh2 reports no status for a signalled peer, and
          // reading that as success is the mistake §19 exists to prevent.
          _exitCode = session.exitCode;
          _emit(remoteExitNotice(session.exitCode));
          _liveness.value = PaneLiveness.exited;
        }, onError: (Object error) {
          _exited = true;
          if (_disposed) return;
          _emit(remoteExitNotice(null, reason: '$error'));
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

  /// Runs the pane against the session host, or returns false and lets the tmux
  /// path take over. Every way of returning false says why in the pane first:
  /// "this host runs musl" is an answer the user can act on.
  Future<bool> _startViaHost() async {
    final access = hostAccess;
    if (access == null) return false;
    // Asked before anything is deployed: a pane that is staying with tmux must
    // not cost the machine a seven-megabyte upload it will not use.
    if (await _keepsItsTmuxSession(access)) return false;
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

    // A host we had to start ourselves was not running — after a reboot, or
    // after somebody killed it. Its sessions are gone, and saying so is the
    // honest version of having no supervisor.
    if (deployment.restartedByUs) {
      _emit(
        '\x1b[33m[the session host on ${host.address} was not running and has '
        'been restarted; any sessions it held before are gone]\x1b[0m\r\n',
      );
    }

    if (!await _dialHost(access, deployment, remotePath)) return false;

    // Re-dial on the pool re-establishing the connection, not on a timer: the
    // app already observes that transition.
    _reconnects ??= access.reconnected.listen((_) => unawaited(_reconnectToHost(access)));
    return true;
  }

  /// Whether this pane's session is already under tmux, in which case it stays
  /// there: both carry the same name, so the host path would open an empty one.
  Future<bool> _keepsItsTmuxSession(HostSessionAccess access) async {
    final name = _hostSessionId();
    final bool? existing;
    try {
      existing = await access.hasTmuxSession(name);
    } on Object catch (e) {
      _emit(
        '\x1b[33m[could not ask ${host.address} whether $name is already running '
        'under tmux ($e), so this pane stays on tmux rather than risk leaving a '
        'live session behind it.]\x1b[0m\r\n',
      );
      return true;
    }
    if (existing == null) {
      // A reading nobody took is not a negative one (§19), and the two
      // mistakes do not cost the same: taking the host path wrongly abandons a
      // running agent, staying on tmux wrongly costs command blocks.
      _emit(
        '\x1b[33m[${host.address} did not say whether $name is already running under '
        'tmux, so this pane stays on tmux.]\x1b[0m\r\n',
      );
      return true;
    }
    if (!existing) return false;
    _emit(
      '\x1b[33m[$name is already running under tmux on ${host.address}; this pane '
      'attaches to it there rather than opening a second session on the session '
      'host. tmux does not carry command blocks, links or exit codes — end this '
      'session and start a new one to move it.]\x1b[0m\r\n',
    );
    return true;
  }

  /// Whether this pane opened holding the app's own record of its history. On
  /// the host path there are two records of the same output — the text the app
  /// stored and the host's ring — and showing both prints the session twice.
  var _hasStoredHistory = false;

  /// Whether this pane attached to a session that already existed, rather than
  /// opening one. Only a resume has a second record to collide with.
  var _resumed = false;

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
    HostPaneLink? link;
    try {
      link = await HostPaneLink.open(
        await access.exec('$remotePath attach'),
        clientId: 'pane-$id',
      );
      if (_disposed) {
        await link.close();
        return true;
      }
      _link = link;

      // The session id is the pane's own, stable across reattach. `attach`
      // first: on a reconnect the session is already there and asking to open
      // it would be refused.
      final attachment = await _attachOrOpen(link, width, height, resumeFrom);
      // Read now, not from `width`: the layout can land while the attach is out.
      link.matchGrid(attachment, terminal.viewWidth, terminal.viewHeight);
      if (_resumed && _hasStoredHistory && attachment.totalBytes > 0) {
        // The replay is the more accurate record, so the stored copy goes.
        // Erase scrollback as well: a plain clear leaves it one scroll away.
        terminal.write('\x1b[H\x1b[2J\x1b[3J');
        _hasStoredHistory = false;
      }
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
      // Left open, the channel would hold the write token of a session that
      // may well be running.
      if (link != null) unawaited(link.close().catchError((Object _) {}));
      _logger.error('Session host on ${host.address} refused a pane: $e');
      // No answer is not a refusal: the host may have started the agent, and
      // the tmux fallback would start a second one under the same name.
      if (e is HostLinkException && e.timedOut) {
        _exited = true;
        _emit(
          '\r\n\x1b[31m[the session host on ${host.address} did not answer '
          '($e). Reopen this pane to try again.]\x1b[0m\r\n',
        );
        _liveness.value = PaneLiveness.exited;
        return true;
      }
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
      final attachment = await link.attachSession(
        sessionId: sessionId,
        sinceOffset: sinceOffset,
      );
      _resumed = true;
      return attachment;
    } on HostLinkException catch (e) {
      // Only the host saying there is no such session earns an open. A timeout
      // or any other refusal may mean the session is there and alive.
      if (e.code != ProtocolErrorCode.unknownSession) rethrow;
      final launch = agentLaunch;
      // The host spawns exactly this argv, so a shell pane has to name the
      // user's own shell: `/bin/sh` is what tmux never gave them.
      final shell = launch == null ? await hostAccess?.loginShell() : null;
      return link.openSession(
        sessionId: sessionId,
        argv: launch == null
            ? [shell ?? '/bin/sh', '-l']
            : [launch.executable, ...launch.commandArguments],
        workingDirectory: workingDirectory,
        environment: const {'TERM': 'xterm-256color'},
        columns: width,
        rows: height,
      );
    }
  }

  /// The app's own id, not one the host invents: literally [sshTmuxSessionName],
  /// because a session cannot be in both places under two names.
  String _hostSessionId() =>
      sshTmuxSessionName(paneId: id, hostId: host.id, agentSessionId: agentLaunch?.sessionId);

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
    // Deliberately still `live`: a process *is* running behind this buffer, and
    // calling it `exited` would be the false statement. A `disconnected` state
    // would be the honest third answer, and belongs in its own change.
  }

  void _onHostSessionEnded(HostSessionEnd end) {
    _exited = true;
    if (_disposed) return;
    _exitCode = end.exitCode;
    _emit(remoteExitNotice(end.exitCode, reason: end.reason));
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
      unawaited(
        session.done.whenComplete(() {
          if (!reap.isCompleted) reap.complete();
        }).catchError((Object _) {}),
      );
    }
  }
}

/// Builds the command handed to the remote login shell. Kept pure so quoting
/// and tmux identity can be verified without opening a socket; SSH transmits
/// one command string, so every dynamic value crosses through [_posixQuote].
@visibleForTesting
String buildSshTerminalScript({
  required String paneId,
  required String hostId,
  String? workingDirectory,
  AgentPaneLaunch? agentLaunch,
}) {
  final cwd = workingDirectory?.trim();
  final hasCwd = cwd != null && cwd.isNotEmpty;
  final tmuxSessionName = sshTmuxSessionName(
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

/// The name one pane's remote session goes by — under tmux, and under the
/// session host, which use the same string on purpose.
@visibleForTesting
String sshTmuxSessionName({
  required String paneId,
  required String hostId,
  String? agentSessionId,
}) {
  // A session id keeps an agent attached to its remote process across local
  // pane replacement; a pane id gives each plain shell its own tmux session
  // (using only the host id made every terminal on one host share input).
  final raw = agentSessionId != null
      ? 'karmashala_$agentSessionId'
      : 'karmashala_${hostId}_$paneId';
  return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
}

String _posixQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
