import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import '../../../core/logging/app_logger.dart';
import '../../ssh/data/host_session_access.dart';
import '../../ssh/domain/host_deployment.dart';
import '../domain/agent_pane_launch.dart';
import '../domain/enter_key_encoding.dart';
import '../domain/ingest_tier.dart';
import '../domain/launch_context.dart';
import '../domain/osc_router.dart';
import '../domain/pane_liveness.dart';
import '../domain/scrollback_limits.dart';
import '../domain/terminal_profile.dart';
import 'cast_recorder.dart';
import 'cold_screen.dart';
import 'command_block_recorder.dart';
import 'host_pane_link.dart';
import 'pty_output_coalescer.dart';
import 'pty_launch.dart';
import 'terminal_grid_text.dart';
import 'terminal_ingest_budget.dart';
import 'terminal_instance.dart';

/// A pane whose process belongs to the **session host** rather than to this
/// app, on this machine.
///
/// The point of it, and the reason it is a separate class from
/// [PtyTerminalInstance] rather than a flag on it: a `flutter_pty` child is
/// this process's child, so an app crash takes every agent with it. A session
/// the host owns outlives the app, the pane and the window, and a reopened pane
/// resumes it from the exact byte it last rendered.
///
/// It is the same conversation `SshTerminalInstance` has over an SSH exec
/// channel — the same [HostPaneLink], the same frames, the same offsets — with
/// two things absent because there is no network: no deploy (the binary is
/// beside the app or it is not) and no reconnect (a unix socket does not drop
/// and come back).
///
/// **There is no fallback here on purpose.** The SSH pane falls back to tmux
/// because tmux is what was there before it; the local pane's "before" is
/// `flutter_pty`, and choosing between them is the *setting's* job, decided
/// once at launch by `terminalInstanceFactoryProvider`. A pane that got here
/// and cannot reach the host says so and stays dead, rather than silently
/// becoming the thing the user turned off.
class HostTerminalInstance
    implements
        TerminalInstance,
        ReapableTerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance,
        RecordableTerminalInstance {
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
  }) : _logger = logger ?? AppLogger.named('terminal.host'),
       _cwd = WorkingDirectoryTracker(workingDirectory) {
    terminal = adoptTerminal ?? Terminal(maxLines: kLiveScrollbackMaxLines)
      ..inputHandler = const KarmashalaInputHandler()
      ..onPrivateOSC = _osc.dispatch
      ..onCurrentDirectoryChange = (uri) => _osc.dispatch('7', [uri]);

    _osc.add(_cwd.handleOsc);

    if (adoptTerminal == null) {
      _hasStoredHistory = restoredScrollback != null && restoredScrollback.isNotEmpty;
      writeRestoredScrollback(terminal, restoredScrollback);
    } else {
      _hasStoredHistory = nonBlankLineCount(terminal) > 0;
      writeRestoreMarker(terminal);
    }

    _coalescer = PtyOutputCoalescer(onData: terminal.write, budget: ingestBudget);
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
  /// interface an SSH pane is handed, which is what lets one pane class serve
  /// two transports.
  final HostSessionAccess access;

  /// What to run, already built for where it is going by `ptyLaunchFor` /
  /// `agentPtyLaunchFor` — the same launch a `flutter_pty` pane would have
  /// spawned, handed to the host instead of to this process.
  final PtyLaunch launch;

  @override
  final AgentPaneLaunch? agentLaunch;
  final Terminal? adoptTerminal;

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

  /// Null, always: OSC 133 markers come from a shell's prompt hooks, and the
  /// host path does not install them. Said here rather than left to a reader of
  /// the base class, because it is what makes `terminal_run` refuse to claim an
  /// exit code for a command in this pane.
  @override
  CommandBlockRecorder? commandBlocks;

  @override
  String? get workingDirectory => _cwd.value;

  @override
  ValueListenable<String?> get directory => _cwd.listenable;

  final ValueNotifier<PaneLiveness> _liveness = ValueNotifier(PaneLiveness.live);

  @override
  ValueListenable<PaneLiveness> get liveness => _liveness;

  int? _exitCode;

  /// What the *session* exited with, as the host reported it.
  ///
  /// Null is a real answer and never a zero: a session whose host was restarted
  /// under it ended with no code at all, and the host says which of the two it
  /// was rather than inventing one.
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

  /// Whether this pane opened holding the app's own record of its history.
  ///
  /// It matters because on the host path there are two records of the same
  /// output — the text the app stored when it last closed, and the host's ring
  /// — and showing both would print the session twice. See [_dial].
  var _hasStoredHistory = false;

  @override
  Future<void> get reaped => _reap?.future ?? Future<void>.value();

  @override
  IngestTier get ingestTier => _tier;

  @override
  String? get parkedScrollback => _cold.parkedScrollback;

  @override
  Terminal? get adoptableBuffer =>
      _exited && !_cold.isParked && !terminal.isUsingAltBuffer ? terminal : null;

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
      _fail('Could not ask the session host on ${access.address} about itself: $e');
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
    if (deployment.restartedByUs) {
      _emit(
        '\x1b[33m[the session host was not running and has been started; any '
        'session it held before is no longer running]\x1b[0m\r\n',
      );
    }

    await _dial(deployment);
  }

  Future<void> _dial(HostDeployment deployment) async {
    final width = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
    final height = terminal.viewHeight > 0 ? terminal.viewHeight : 24;
    final resumeFrom = _lastOffset;
    try {
      final link = await HostPaneLink.open(
        await access.exec('${deployment.remotePath} attach'),
        clientId: 'pane-$id',
      );
      if (_disposed) {
        await link.close();
        return;
      }
      _link = link;

      final attachment = await _attachOrOpen(link, width, height, resumeFrom);
      if (_resumed && _hasStoredHistory && attachment.totalBytes > 0) {
        // Two records of one session: the text this app stored when it last
        // closed, and the ring the host kept. The replay about to arrive is the
        // more accurate of the two — it is the session's own bytes rather than
        // a re-encoding of a buffer — so the stored copy goes rather than being
        // printed above an identical one. Erase display *and* scrollback: a
        // plain clear leaves the history one scroll away.
        terminal.write('\x1b[H\x1b[2J\x1b[3J');
        _hasStoredHistory = false;
      }
      _emit(
        '\x1b[90m[session host ${deployment.hostVersion ?? 'unknown'}: '
        '${attachment.sessionId}, ${attachment.totalBytes} bytes so '
        'far]\x1b[0m\r\n',
      );

      _output = link.output.listen(_onDataBytes, onDone: _onLinkClosed);
      _notices = link.notices.listen((n) => _emit('\r\n\x1b[33m[$n]\x1b[0m\r\n'));
      unawaited(link.ended.then(_onSessionEnded));
    } on Object catch (e) {
      _link = null;
      _logger.error('The local session host refused pane $id: $e');
      _fail('The session host could not start this pane: $e');
    }
  }

  /// Reattaches from the last offset this pane rendered; opens only when there
  /// is no such session yet.
  ///
  /// The order matters after a host restart: the session id is stable across
  /// pane replacement, so `attach` finds the *record* of a session whose
  /// process died with the host. That is the right thing to show — it is the
  /// scrollback the user was reading — and [_onSessionEnded] closes it once it
  /// has been shown, so the next start of this pane opens a live one rather
  /// than replaying a dead one for ever.
  Future<HostAttachment> _attachOrOpen(
    HostPaneLink link,
    int width,
    int height,
    int sinceOffset,
  ) async {
    final sessionId = hostSessionId;
    try {
      final attachment = await link.attachSession(
        sessionId: sessionId,
        sinceOffset: sinceOffset,
      );
      _resumed = true;
      return attachment;
    } on HostLinkException {
      // No such session: this pane's first run.
      return link.openSession(
        sessionId: sessionId,
        argv: [launch.executable, ...launch.arguments],
        workingDirectory: launch.workingDirectory ?? workingDirectory,
        environment: {'TERM': 'xterm-256color', ...launch.environment},
        columns: width,
        rows: height,
      );
    }
  }

  /// Whether this pane attached to a session that already existed, rather than
  /// opening one. It decides what an immediate end means: a session we opened
  /// and that ended is a command that finished, and one we merely found is a
  /// leftover to clear away.
  var _resumed = false;

  /// The app's own id, not one the host invents: the same pane must find the
  /// same session after the app restarts, and an agent must keep its session
  /// across pane replacement — the rule the SSH pane and the tmux session name
  /// both follow.
  @visibleForTesting
  String get hostSessionId {
    final raw = agentLaunch?.sessionId != null
        ? 'karmashala_${agentLaunch!.sessionId}'
        : 'karmashala_local_$id';
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  void _onLinkClosed() {
    _lastOffset = _link?.lastOffset ?? _lastOffset;
    _link = null;
    if (_disposed || _exited) return;
    // The link went away, not the session. There is no reconnect event on a
    // local socket, so the honest thing is to say what happened and what
    // reopening the pane will do.
    _emit(
      '\r\n\x1b[33m[the link to the session host closed. The session is still '
      'there; reopening this pane resumes it from byte $_lastOffset.]\x1b[0m\r\n',
    );
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
    // write token and the session keeps running for the next pane. That is the
    // whole reason this class exists.
    unawaited(
      link.close().whenComplete(() {
        if (!reap.isCompleted) reap.complete();
      }),
    );
  }
}

/// Builds the launch for [profile] and hands it to the session host.
///
/// The launch is built by exactly the same functions `createPtyTerminalInstance`
/// uses, so a host-backed pane starts the same command line a `flutter_pty`
/// pane would have — the difference is only whose child it is.
///
/// **Shell integration is never asked for here**, and that is the honest
/// version rather than an oversight: OSC 133 comes from a bootstrap this app
/// injects into a PowerShell launch, and the marker stream would arrive through
/// the host unchanged — but nothing above this has been measured against it, so
/// offering it would be claiming something nobody has checked. A host-backed
/// pane reports no command blocks and `terminal_run` therefore refuses to name
/// an exit code for a command typed into one, which is the truthful answer.
TerminalInstance createHostTerminalInstance({
  required String id,
  required TerminalProfile profile,
  required HostSessionAccess access,
  String? workingDirectory,
  String? restoredScrollback,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
  Map<String, String> environmentOverlay = const {},
}) {
  final PtyLaunch launch;
  final String title;
  final String profileId;
  if (agentLaunch != null) {
    launch = agentPtyLaunchFor(
      agentLaunch,
      context: LaunchContext.forAgent(agentLaunch, hostIsWindows: Platform.isWindows),
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
  );
}
