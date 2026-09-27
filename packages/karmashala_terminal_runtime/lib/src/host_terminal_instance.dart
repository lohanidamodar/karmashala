import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'cast_recorder.dart';
import 'cold_screen.dart';
import 'command_block_recorder.dart';
import 'package:karmashala_host/protocol.dart' show ProtocolErrorCode;
import 'host_pane_link.dart';
import 'local_host_access.dart';
import 'pane_terminal.dart';
import 'pty_output_coalescer.dart';
import 'pty_launch.dart';
import 'terminal_grid_text.dart';
import 'terminal_ingest_budget.dart';
import 'terminal_instance.dart';

/// The host session pane [paneId] owns: the app's own id rather than one the
/// host invents, so the same pane finds the same session after the app restarts
/// and an agent keeps its session across pane replacement. One function, because
/// the restore asks the host which of these are still running before any pane
/// exists to ask.
String hostSessionIdFor({required String paneId, String? agentSessionId}) {
  final raw = agentSessionId != null
      ? 'karmashala_$agentSessionId'
      : 'karmashala_local_$paneId';
  return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
}

/// How long a pane waits before each attempt to reach its host again after the
/// link closed. Bounded: a host that stays away is said so, not polled for.
const List<Duration> kHostRedialDelays = [
  Duration(milliseconds: 250),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

/// A pane whose process belongs to the **session host**, so it outlives the app
/// a `flutter_pty` child would die with. No fallback: it says so and stays dead.
class HostTerminalInstance
    implements
        TerminalInstance,
        ReapableTerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance,
        RecordableTerminalInstance,
        HostedTerminalInstance {
  HostTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required this.access,
    required this.launch,
    String? workingDirectory,
    this.agentLaunch,
    this.adoptTerminal,
    String? restoredScrollback,
    TerminalIngestBudget? ingestBudget,
    AppLogger? logger,
    bool shellIntegration = false,
    this.redialDelays = kHostRedialDelays,
  }) : _logger = logger ?? AppLogger.named('terminal.host'),
       _cwd = WorkingDirectoryTracker(workingDirectory) {
    terminal = adoptTerminal ?? PaneTerminal(maxLines: kLiveScrollbackMaxLines)
      ..inputHandler = const KarmashalaInputHandler()
      ..onPrivateOSC = _osc.dispatch
      ..onCurrentDirectoryChange = (uri) => _osc.dispatch('7', [uri]);

    _osc.add(_cwd.handleOsc);
    // Before any byte arrives, as on the PTY path, so no marker is missed.
    if (shellIntegration) {
      commandBlocks = CommandBlockRecorder(terminal)..attach(_osc);
    }

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
      _link?.write(Uint8List.fromList(utf8.encode(data)));
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_disposed) return;
      _recorder?.addResize(width, height);
      _link?.resize(width, height);
    };

    unawaited(_start());
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;

  /// This machine's session host: the reading and the channel. The same
  /// interface an SSH pane is handed, so one pane class serves two transports.
  final HostSessionAccess access;

  /// What to run, already built for where it is going by `ptyLaunchFor` /
  /// `agentPtyLaunchFor` — the same launch a `flutter_pty` pane would have
  /// spawned, handed to the host instead of to this process.
  final PtyLaunch launch;

  @override
  final AgentPaneLaunch? agentLaunch;
  final Terminal? adoptTerminal;

  /// See [kHostRedialDelays]; shorter in tests.
  final List<Duration> redialDelays;

  final AppLogger _logger;
  final WorkingDirectoryTracker _cwd;
  final OscRouter _osc = OscRouter();

  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  /// The OSC 133 blocks, when the pane was launched with shell integration —
  /// the same bootstrap the PTY path uses, handed to the host. Null otherwise,
  /// which is what makes `terminal_run` refuse to claim an exit code here.
  @override
  CommandBlockRecorder? commandBlocks;

  @override
  String? get workingDirectory => _cwd.value;

  @override
  ValueListenable<String?> get directory => _cwd.listenable;

  final ValueNotifier<PaneLiveness> _liveness = ValueNotifier(
    PaneLiveness.live,
  );

  @override
  ValueListenable<PaneLiveness> get liveness => _liveness;

  int? _exitCode;

  /// What the *session* exited with, as the host reported it. Null is a real
  /// answer and never a zero: a session whose host was restarted under it ended
  /// with no code at all, and the host says which of the two it was.
  @override
  int? get exitCode => _exitCode;

  int? _greetingLines;
  @override
  int? get greetingLines => _greetingLines;

  late final PtyOutputCoalescer _coalescer;
  late final ColdIngest _cold;
  IngestTier _tier = IngestTier.hot;

  HostPaneLink? _link;
  StreamSubscription<Uint8List>? _output;
  StreamSubscription<String>? _notices;
  CastRecorder? _recorder;
  Completer<void>? _reap;
  var _disposed = false;
  var _exited = false;

  /// What the pane has actually rendered. Kept across a link being replaced so
  /// a re-dial neither repeats a byte nor drops one.
  int _lastOffset = 0;

  /// The host this pane's session runs in, by the pid and start time its
  /// welcome gave. A redial that meets another host has met a replacement:
  /// the session died with the one before it.
  (int, DateTime)? _hostIdentity;

  /// Whether this pane opened holding the app's own record of its history: on
  /// the host path there are two records of the same output, and showing both
  /// would print the session twice. See [_dial].
  var _hasStoredHistory = false;

  @override
  Future<void> get reaped => _reap?.future ?? Future<void>.value();

  @override
  IngestTier get ingestTier => _tier;

  @override
  String? get parkedScrollback => _cold.parkedScrollback;

  @override
  Terminal? get adoptableBuffer =>
      _exited && !_cold.isParked && !terminal.isUsingAltBuffer
      ? terminal
      : null;

  @override
  CastRecorder? get recorder => _recorder;

  @override
  void startRecording(CastRecorder recorder) => _recorder = recorder;

  @override
  void stopRecording() => _recorder = null;

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

  void _recordGreeting(String submitted) {
    if (_greetingLines != null || !submitted.contains('\r')) return;
    _greetingLines = nonBlankLineCount(terminal);
  }

  void _onDataBytes(List<int> bytes) {
    if (_disposed) return;
    final uint8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    _recorder?.addOutput(uint8);
    if (_tier == IngestTier.cold) {
      _cold.add(uint8);
      return;
    }
    _coalescer.add(uint8);
  }

  /// The absolute offset a reattach's replay ends at while its bytes are still
  /// arriving, and null once the pane is live. See [_onLinkBytes].
  int? _replayEndsAt;
  int _receivedOffset = 0;

  /// Replay bytes still to be dropped unread — see [_skipsReplay].
  int _discardRemaining = 0;

  /// The link's bytes, with the end of a reattach's replay marked in the
  /// ingest itself: the recorder reads the replay for state only, and the mark
  /// has to reach it in order with the bytes however the ingest batches them.
  void _onLinkBytes(Uint8List bytes) {
    if (_discardRemaining > 0) {
      if (bytes.length <= _discardRemaining) {
        _discardRemaining -= bytes.length;
        return;
      }
      bytes = Uint8List.sublistView(bytes, _discardRemaining);
      _discardRemaining = 0;
    }
    final end = _replayEndsAt;
    if (end == null) {
      _onDataBytes(bytes);
      return;
    }
    final remaining = end - _receivedOffset;
    if (bytes.length < remaining) {
      _receivedOffset += bytes.length;
      _onDataBytes(bytes);
      return;
    }
    if (remaining > 0) _onDataBytes(Uint8List.sublistView(bytes, 0, remaining));
    _markReplayEnd();
    if (bytes.length > remaining) {
      _onDataBytes(Uint8List.sublistView(bytes, remaining));
    }
  }

  /// Through the same queue as the process's bytes — never straight into the
  /// terminal, which would overtake whatever the coalescer still holds — and
  /// never into a recording, since the process did not write it.
  void _markReplayEnd() {
    _replayEndsAt = null;
    if (_disposed) return;
    final mark = Uint8List.fromList(
      utf8.encode(CommandBlockRecorder.replayEndSequence),
    );
    if (_tier == IngestTier.cold) {
      _cold.add(mark);
    } else {
      _coalescer.add(mark);
    }
  }

  /// The pane's own bookkeeping — which host, which session, that it
  /// reconnected. Into the terminal in a debug build only: in a release one
  /// that is the program's screen, the ids mean nothing to the person, and the
  /// line sits where the program's next redraw expects its own rows
  /// (2026-09-24). The log has it either way.
  void _note(String text) {
    _logger.info(text.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '').trim());
    if (writesNotesToTerminal) _emit(text);
  }

  /// [kDebugMode], and settable so a test can see what a release pane shows.
  @visibleForTesting
  static bool writesNotesToTerminal = kDebugMode;

  void _emit(String text) {
    _recorder?.addText(text);
    if (_tier == IngestTier.cold) {
      _cold.emit(text);
      return;
    }
    terminal.write(text);
  }

  Future<void> _start() async {
    final HostDeployment deployment;
    try {
      deployment = await access.deployment();
    } on Object catch (e) {
      _fail(
        'Could not ask the session host on ${access.address} about itself: $e',
      );
      return;
    }
    if (_disposed) return;
    if (!deployment.isReady) {
      _fail('The session host is not available: ${deployment.reason}');
      return;
    }

    // A host we had to start ourselves is a host that was not running. It still
    // holds what it recorded — a pane reattaching gets its scrollback and the
    // reason its process is gone — but nothing is running in it.
    if (deployment.restartedByUs) _sayRestarted();

    await _dial(deployment);
  }

  void _sayAdopted() => _note(
    '\x1b[90m[the host had already started this session; attached to it '
    'rather than starting a second]\x1b[0m\r\n',
  );

  void _sayRestarted() => _note(
    '\x1b[33m[the session host was not running and has been started; any '
    'session it held before is no longer running]\x1b[0m\r\n',
  );

  /// Reaches the host again after the link closed. The session lives only as
  /// long as the host that runs it, so a redial reattaches only to *that*
  /// host: one that only dropped the socket is simply redialled, and a
  /// replacement, or nobody at all, ends the pane honestly — no code, never a
  /// fresh session opened in its place. This machine's host is started again
  /// by its supervisor, never by a pane, so a local pane only looks. A host
  /// that answers but is not ready is waited for — an unanswered handshake is
  /// not evidence that nobody is there.
  Future<void> _redial() async {
    var nobody = 0;
    for (final delay in redialDelays) {
      await Future<void>.delayed(delay);
      if (_disposed || _exited || _link != null) return;
      final local = access;
      final HostDeployment deployment;
      try {
        deployment = local is LocalHostSessionAccess
            ? await local.observe()
            : await access.deployment();
      } on Object catch (e) {
        _logger.debug('pane $id could not ask its host again: $e');
        continue;
      }
      if (_disposed || _exited) return;
      if (local is LocalHostSessionAccess) {
        // Another protocol on the socket is another host: ours has gone.
        if (deployment.status == HostDeploymentStatus.protocolMismatch) {
          _endedWithHost(_hostStopped);
          return;
        }
        // Twice, so one refused connect under load is not taken for a death.
        if (_nobodyThere(deployment) && ++nobody >= 2) {
          _endedWithHost(_hostStopped);
          return;
        }
      }
      if (!deployment.isReady) continue;
      if (await _dial(deployment, redialing: true)) return;
    }
    if (_disposed || _exited) return;
    _emit(
      '\r\n\x1b[33m[could not reach the session host again. The session may '
      'still be there; reopening this pane resumes it from byte '
      '$_lastOffset.]\x1b[0m\r\n',
    );
  }

  static const _hostStopped =
      'the session host stopped, and this session ended with it';

  /// Whether [reading] says nothing listens on this machine's socket.
  static bool _nobodyThere(HostDeployment reading) =>
      reading.status == HostDeploymentStatus.noBinary ||
      (reading.status == HostDeploymentStatus.unknown &&
          !reading.hostUnresponsive);

  /// Ends the pane because its session is gone with no code to report.
  void _endedWithHost(String why) {
    if (_exited || _disposed) return;
    _exited = true;
    _exitCode = null;
    _emit('\r\n\x1b[90m[$why; no exit code]\x1b[0m\r\n');
    _liveness.value = PaneLiveness.exited;
  }

  /// Answers whether the pane is attached. A first dial that fails ends the
  /// pane; a redial that fails leaves [_redial] to try again; a redial that
  /// finds the session gone ends it honestly and counts as handled.
  Future<bool> _dial(
    HostDeployment deployment, {
    bool redialing = false,
  }) async {
    final width = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
    final height = terminal.viewHeight > 0 ? terminal.viewHeight : 24;
    final resumeFrom = _lastOffset;
    HostPaneLink? link;
    try {
      link = await HostPaneLink.open(
        await access.exec('${deployment.remotePath} attach'),
        clientId: 'pane-$id',
      );
      if (_disposed) {
        await link.close();
        return false;
      }
      final welcome = link.welcome;
      final identity = welcome == null
          ? null
          : (welcome.pid, welcome.startedAt.toUtc());
      if (redialing &&
          _hostIdentity != null &&
          identity != null &&
          identity != _hostIdentity) {
        await link.close();
        _endedWithHost(_hostStopped);
        return true;
      }
      _hostIdentity ??= identity;
      _link = link;

      final attachment = await _attachOrOpen(
        link,
        width,
        height,
        resumeFrom,
        deployment,
        redialing: redialing,
      );
      final skip = _skipsReplay(attachment, resumeFrom);
      if (skip) {
        _discardRemaining = attachment.totalBytes - attachment.replayFromOffset;
      }
      // Read now, not from `width`: the layout can land while the attach is out.
      link.matchGrid(attachment, terminal.viewWidth, terminal.viewHeight);
      if (attachment.screenFollows) {
        // The screen resets the terminal before drawing, stored copy and all.
        _hasStoredHistory = false;
      } else if (!skip &&
          _resumed &&
          _hasStoredHistory &&
          attachment.totalBytes > 0) {
        // The replay is the more accurate record, so the stored copy goes.
        // Erase scrollback as well: a plain clear leaves it one scroll away.
        terminal.write('\x1b[H\x1b[2J\x1b[3J');
        _hasStoredHistory = false;
      }
      // Not over a screen, which would erase it and whose program would
      // otherwise redraw over it.
      if (!attachment.screenFollows) {
        _note(
          '\x1b[90m[session host ${deployment.hostVersion ?? 'unknown'}: '
          '${attachment.sessionId}, ${attachment.totalBytes} bytes so '
          'far]\x1b[0m\r\n',
        );
      }

      // A session found rather than opened replays output no pane watched: its
      // markers say where the shell is now, but its blocks would carry this
      // moment's timestamps, so they are read for state only.
      final recorder = commandBlocks;
      if (_resumed && recorder != null) {
        recorder.beginReplay();
        if (!skip && attachment.totalBytes > attachment.replayFromOffset) {
          _replayEndsAt = attachment.totalBytes;
          _receivedOffset = attachment.replayFromOffset;
        } else {
          _markReplayEnd();
        }
      }

      _output = link.output.listen(_onLinkBytes, onDone: _onLinkClosed);
      _notices = link.notices.listen(
        (n) => _emit('\r\n\x1b[33m[$n]\x1b[0m\r\n'),
      );
      unawaited(link.ended.then(_onSessionEnded));
      // What is on screen now belongs to the live session: a later redial
      // replays from where the pane stopped, and must never clear it.
      _hasStoredHistory = false;
      return true;
    } on _SessionGone {
      _link = null;
      if (link != null) unawaited(link.close().catchError((Object _) {}));
      _endedWithHost('the session host no longer holds this session');
      return true;
    } on Object catch (e) {
      _link = null;
      if (link != null) unawaited(link.close().catchError((Object _) {}));
      if (redialing) {
        _logger.debug('pane $id could not redial its host: $e');
        return false;
      }
      _logger.error('The local session host refused pane $id: $e');
      _fail('The session host could not start this pane: $e');
      return false;
    }
  }

  /// Reattaches from the last offset this pane rendered, opening only when
  /// there is no session. A dead record is shown once, then closed.
  Future<HostAttachment> _attachOrOpen(
    HostPaneLink link,
    int width,
    int height,
    int sinceOffset,
    HostDeployment deployment, {
    required bool redialing,
  }) async {
    final sessionId = hostSessionId;
    // An agent launched now whose record the host kept after it exited —
    // `claude` quit with Ctrl-C twice — would otherwise be reattached to that
    // record, show its exit, and never run again, however often it is resumed.
    if (agentLaunch != null &&
        sinceOffset == 0 &&
        await _endedOnHost(link, sessionId)) {
      await link.closeSession(sessionId);
    }
    try {
      final attachment = await link.attachSession(
        sessionId: sessionId,
        sinceOffset: sinceOffset,
        // A pane with nothing of the session yet asks for its screen: the
        // program's relative redraws replayed onto an empty one stack up.
        screenGrid: sinceOffset == 0 ? (width, height) : null,
      );
      _resumed = true;
      return attachment;
    } on HostLinkException catch (e) {
      // Only the host saying there is no such session earns an open. A timeout
      // or any other refusal may mean the session is there and alive.
      if (e.code != ProtocolErrorCode.unknownSession) rethrow;
      // A pane coming back to its session never starts another in its place.
      if (redialing) throw const _SessionGone();
    }
    // An older host still serves the sessions it holds, but a new one started
    // in it would run with that build's behaviour.
    if (deployment.hostOutdated) {
      throw const HostLinkException(outdatedHostRefusal);
    }
    try {
      return await link.openOrAdopt(
        sessionId,
        adopted: _sayAdopted,
        () => link.openSession(
          sessionId: sessionId,
          // The host starts argv[0] once and quotes by CommandLineToArgvW rules,
          // so a WSL launch goes without the `cmd.exe /c` flutter_pty needs.
          argv: launch.hostArgv,
          // The launch's own, never the pane's: a WSL launch leaves it null on
          // purpose and carries the Linux folder as `--cd`, which Windows'
          // CreateProcess would refuse as a process directory (errno 267).
          workingDirectory: launch.workingDirectory,
          environment: {'TERM': 'xterm-256color', ...launch.environment},
          removedEnvironment: launch.removedEnvironment,
          columns: width,
          rows: height,
        ),
      );
    } on HostLinkException catch (e) {
      if (e.code != ProtocolErrorCode.badRequest ||
          launch.removedEnvironment.isEmpty) {
        rethrow;
      }
      throw HostLinkException(
        withholdingRefusal(launch.removedEnvironment, e.message),
        code: e.code,
      );
    }
  }

  /// Whether the host holds [sessionId] as an ended record. Not being able to
  /// ask is not a yes: the attach that follows decides as it always did.
  Future<bool> _endedOnHost(HostPaneLink link, String sessionId) async {
    try {
      return (await link.listSessions()).any(
        (s) => s.id == sessionId && s.lifecycle.hasEnded,
      );
    } on HostLinkException {
      return false;
    }
  }

  /// Whether a fresh pane shows the app's own record of itself instead of the
  /// host's replay. An agent's TUI redraws by relative cursor moves counted at
  /// the width it drew at, so its replay at today's width is debris, while the
  /// stored record is plain text. Only with a record: the agent does not
  /// reprint its conversation when told a size, so with nothing stored the
  /// replay — garbled or not — is all there is to show.
  bool _skipsReplay(HostAttachment attachment, int resumeFrom) =>
      agentLaunch != null &&
      _hasStoredHistory &&
      _resumed &&
      resumeFrom == 0 &&
      attachment.totalBytes > attachment.replayFromOffset;

  @override
  bool get outlivesApp => !_disposed && !_exited && _link != null;

  @override
  Future<void> endHostedSession() =>
      _link?.closeSession(hostSessionId) ?? Future<void>.value();

  @override
  String get keptBy => 'the session host';

  /// Whether this pane attached to a session that already existed. It decides
  /// what an immediate end means: one we opened and that ended is a command
  /// that finished, one we merely found is a leftover to clear away.
  var _resumed = false;

  /// The app's own id, not one the host invents: the same pane must find the
  /// same session after the app restarts, and an agent must keep its session
  /// across pane replacement.
  @visibleForTesting
  String get hostSessionId =>
      hostSessionIdFor(paneId: id, agentSessionId: agentLaunch?.sessionId);

  void _onLinkClosed() {
    _lastOffset = _link?.lastOffset ?? _lastOffset;
    _link = null;
    // A replay cut short still ends: a recorder left reading for state only
    // would ignore every marker after it.
    if (_replayEndsAt != null) _markReplayEnd();
    if (_disposed || _exited) return;
    // The link went away; the host may have too. Nothing else notices a host
    // that died, so the pane is what reaches it again.
    _note(
      '\r\n\x1b[33m[the link to the session host closed; reconnecting from '
      'byte $_lastOffset]\x1b[0m\r\n',
    );
    unawaited(_redial());
  }

  void _onSessionEnded(HostSessionEnd end) {
    _exited = true;
    if (_disposed) return;
    _exitCode = end.exitCode;
    _emit(
      end.exitCode == null
          // Never a zero: a code the host could not collect is not a success.
          ? '\r\n\x1b[90m[the session ended; exit code unknown '
                '(${end.reason})]\x1b[0m\r\n'
          : '\r\n\x1b[90m[process exited with code ${end.exitCode}]\x1b[0m\r\n',
    );
    _liveness.value = PaneLiveness.exited;
    if (_resumed && end.exitCode == null) {
      // A session we found already over — its host was restarted under it. Its
      // scrollback has now been shown; letting the record go is what makes the
      // next start of this pane a new process rather than the same corpse.
      unawaited(_link?.closeSession(hostSessionId) ?? Future<void>.value());
    }
  }

  void _fail(String message) {
    _exited = true;
    _exitCode = null;
    _emit('\r\n\x1b[31m[$message]\x1b[0m\r\n');
    _liveness.value = PaneLiveness.exited;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _recorder?.sourceEnded();
    _recorder = null;
    _liveness.value = PaneLiveness.exited;
    _liveness.dispose();
    _cwd.dispose();

    unawaited(_output?.cancel());
    unawaited(_notices?.cancel());
    _coalescer.dispose();
    focusNode.dispose();
    scrollController.dispose();

    final link = _link;
    if (link == null) return;
    _link = null;
    final reap = Completer<void>();
    _reap = reap;
    // Closing the link is a *disconnect*, never a kill: the host frees the
    // write token and the session keeps running for the next pane.
    unawaited(
      link.close().whenComplete(() {
        if (!reap.isCompleted) reap.complete();
      }),
    );
  }
}

/// Builds the launch for [profile] and hands it to the session host: the same
/// command line the PTY path builds, shell integration included, decided by
/// the same [shellIntegrationApplies] — so an agent pane never gets it.
TerminalInstance createHostTerminalInstance({
  required String id,
  required TerminalProfile profile,
  required HostSessionAccess access,
  String? workingDirectory,
  String? restoredScrollback,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
  Map<String, String> environmentOverlay = const {},
  bool shellIntegration = false,
}) {
  final PtyLaunch launch;
  final String title;
  final String profileId;
  final integrate = shellIntegrationApplies(
    profile: profile,
    shellIntegration: shellIntegration,
    agentLaunch: agentLaunch,
  );
  if (agentLaunch != null) {
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

  return HostTerminalInstance(
    id: id,
    title: title,
    profileId: profileId,
    access: access,
    launch: launch,
    workingDirectory: workingDirectory,
    agentLaunch: agentLaunch,
    adoptTerminal: adoptTerminal,
    restoredScrollback: restoredScrollback,
    // Windows only, as on the PTY path: elsewhere the launch carries no
    // bootstrap, so there would be no markers to record.
    shellIntegration: integrate && Platform.isWindows,
  );
}

/// Why a pane that had to withhold [names] did not start: the host predates
/// withholding, and starting anyway would hand the child what it must not see.
@visibleForTesting
String withholdingRefusal(Set<String> names, String hostSaid) =>
    'This session host is older than this app and cannot leave '
    '${(names.toList()..sort()).join(', ')} out of a pane, so nothing was '
    'started. Restart the session host from Settings › Terminal, then reopen '
    'this pane. (The host said: $hostSaid)';

/// Why a new pane did not start in an outdated host.
const String outdatedHostRefusal =
    'An older session host, started by an earlier Karmashala, is still '
    'running the sessions it holds, so this pane was not started in it: it '
    'would have run with that version\'s behaviour. Reopen this pane to run it '
    'inside the app, or restart the session host from Settings › Terminal '
    '(that ends the sessions it holds).';

/// A redial found the host holding no session of this pane's id.
class _SessionGone implements Exception {
  const _SessionGone();
}
