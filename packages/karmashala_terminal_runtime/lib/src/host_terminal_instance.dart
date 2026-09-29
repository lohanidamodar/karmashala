import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'cast_recorder.dart';
import 'cold_screen.dart';
import 'command_block_recorder.dart';
import 'package:karmashala_host_protocol/protocol.dart' show ProtocolErrorCode;
import 'host_pane_link.dart';
import 'local_host_access.dart';
import 'pane_terminal.dart';
import 'prompt_typer.dart';
import 'pty_output_coalescer.dart';
import 'shared_host_link.dart';
import 'terminal_grid_text.dart';
import 'terminal_ingest_budget.dart';
import 'terminal_instance.dart';

/// What the server said when asked for a pane's terminal (`terminals.open`):
/// the session to attach to, whether it was already running, and whether its
/// launch carries OSC 133 shell integration.
typedef TerminalOpening = ({
  String sessionId,
  bool adopted,
  bool shellIntegration,
});

/// Asks the server to start this pane's terminal at [columns]×[rows] — or to
/// answer the one already running under its id. The server builds the launch
/// on its own OS (slice 5a); a refusal is thrown in its own words.
typedef TerminalOpener =
    Future<TerminalOpening> Function(int columns, int rows);

/// How long a pane waits before each attempt to reach its host again after the
/// link closed. Bounded: a host that stays away is said so, not polled for.
const List<Duration> kHostRedialDelays = [
  Duration(milliseconds: 250),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

/// **The** live local and WSL pane (slice 5a): its process is a terminal the
/// server runs, so it outlives the app, and this only renders it — attached by
/// session id, with the screen rebuilt from the server's copy. A pane with an
/// [opener] asks the server to start (or adopt) its terminal first; one
/// without only attaches — a hosted run, a worktree setup, a restored pane —
/// and a session that is gone ends it honestly. No fallback: there is no
/// in-app PTY.
class HostTerminalInstance
    implements
        TerminalInstance,
        ReapableTerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance,
        RecordableTerminalInstance,
        PromptTypingTerminalInstance,
        HostedTerminalInstance {
  HostTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required this.access,
    required this.sessionId,
    this.opener,
    this.closer,
    String? workingDirectory,
    this.agentLaunch,
    this.adoptTerminal,
    String? restoredScrollback,
    TerminalIngestBudget? ingestBudget,
    AppLogger? logger,
    bool shellIntegration = false,
    bool drawsAtSessionGrid = false,
    this.redialDelays = kHostRedialDelays,
  }) : _logger = logger ?? AppLogger.named('terminal.host'),
       _cwd = WorkingDirectoryTracker(workingDirectory),
       _atSessionGrid = ValueNotifier(drawsAtSessionGrid) {
    terminal = adoptTerminal ?? PaneTerminal(maxLines: kLiveScrollbackMaxLines)
      ..inputHandler = const KarmashalaInputHandler()
      ..onPrivateOSC = _osc.dispatch
      ..onCurrentDirectoryChange = (uri) => _osc.dispatch('7', [uri]);

    _osc.add(_cwd.handleOsc);
    // Before any byte arrives, so no marker is missed.
    if (shellIntegration) _recordCommandBlocks();

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
      // At the session's grid this size is the session's, never a wish.
      if (drawsAtSessionGrid) return;
      final link = _link;
      if (link != null) _tell(link, width, height);
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

  /// The server session this pane renders (`terminalSessionId`: the pane's
  /// own id, or its agent session row's), so the same pane finds the same
  /// session after the app restarts.
  final String sessionId;

  /// Asks the server for this pane's terminal; null attaches only.
  final TerminalOpener? opener;

  /// Ends the session for good at the server (`terminals.close`); null ends
  /// it over the host link.
  final Future<void> Function()? closer;

  @override
  final AgentPaneLaunch? agentLaunch;
  final Terminal? adoptTerminal;

  /// See [kHostRedialDelays]; shorter in tests.
  final List<Duration> redialDelays;

  /// Attaches to a session somebody else started (a run the server hosts, or
  /// a restored pane's) and never starts one: a session that is gone ends the
  /// pane.
  bool get attachOnly => opener == null;

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

  /// The OSC 133 blocks, when the server's launch carries shell integration.
  /// Null otherwise, which is what makes `terminal_run` refuse to claim an
  /// exit code here.
  @override
  CommandBlockRecorder? commandBlocks;

  void _recordCommandBlocks() {
    commandBlocks ??= CommandBlockRecorder(terminal)..attach(_osc);
  }

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
  StreamSubscription<HostPresence>? _presenceSubscription;
  final ValueNotifier<HostPresence?> _presence = ValueNotifier(null);

  /// Who drives this pane's session and who else watches it (slice 5e), as
  /// the server last said; null before it has.
  ValueListenable<HostPresence?> get presence => _presence;

  /// Takes the session from whoever is typing in it: "Take over".
  Future<void> takeOver() async => _link?.takeOver();

  final ValueNotifier<bool> _atSessionGrid;

  /// Whether this pane draws at the session's grid and pans, rather than
  /// asking the session for its own (Stage 2 step 9). Such a pane attaches
  /// without claiming, so looking never resizes the session, and a keystroke
  /// that takes the input leaves the grid as it is.
  ValueListenable<bool> get atSessionGrid => _atSessionGrid;

  bool get drawsAtSessionGrid => _atSessionGrid.value;

  /// The grid this device's view would hold, as the pane last measured it:
  /// what [fitToView] asks for, and what a terminal this pane starts opens at.
  (int, int)? viewGrid;

  /// The grid this pane last told the server, which keeps it as this
  /// client's wish until it types.
  (int, int)? _toldGrid;

  void _tell(HostPaneLink link, int columns, int rows) {
    _toldGrid = (columns, rows);
    link.resize(columns, rows);
  }

  /// Draws at the session's [columns]×[rows], and tells the server that grid
  /// as this client's wish, so a keystroke that takes the input from here
  /// resizes nothing.
  void _followSessionGrid(
    HostPaneLink link,
    int columns,
    int rows, {
    required bool holds,
  }) {
    if (columns <= 0 || rows <= 0) return;
    if (terminal.viewWidth != columns || terminal.viewHeight != rows) {
      terminal.resize(columns, rows);
    }
    if (!holds && _toldGrid != (columns, rows)) _tell(link, columns, rows);
  }

  /// "Fit to this phone": the session takes this view's grid, and this client
  /// the input. The one way a pane at the session's grid resizes it.
  Future<void> fitToView() async {
    if (!drawsAtSessionGrid) return;
    _atSessionGrid.value = false;
    final grid = viewGrid;
    if (grid != null) terminal.resize(grid.$1, grid.$2);
    final link = _link;
    if (link == null) return;
    // Said again in case the resize above changed nothing locally.
    _tell(link, terminal.viewWidth, terminal.viewHeight);
    await link.takeOver();
  }

  /// Back to the session's grid after [fitToView]. The session stays at the
  /// size it was fitted to until whoever drives it next resizes it.
  void drawAtSessionGrid() {
    if (drawsAtSessionGrid) return;
    _atSessionGrid.value = true;
    final told = _presence.value;
    final link = _link;
    if (told == null || link == null) return;
    _followSessionGrid(link, told.columns, told.rows, holds: told.mine);
  }

  final ValueNotifier<DateTime?> _refusedAt = ValueNotifier(null);

  /// When a keystroke from here was last refused because someone else typed
  /// within the idle window.
  ValueListenable<DateTime?> get keystrokeRefusedAt => _refusedAt;
  StreamSubscription<void>? _refusals;
  CastRecorder? _recorder;
  Completer<void>? _reap;
  var _disposed = false;

  /// Completes on [dispose], so a wait for the client's next link ends with
  /// the pane rather than outliving it.
  final _gone = Completer<void>();
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

  /// Through `textInput`, so it takes the road a keystroke takes — a
  /// command left at a box's prompt (a `sudo` step) and never submitted.
  late final PromptTyper _typer = PromptTyper(send: terminal.textInput);

  @override
  void typeAtPrompt(String text) => _typer.type(text);

  void _onDataBytes(List<int> bytes) {
    if (_disposed) return;
    _typer.onOutput();
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
      'still be there; this pane reattaches from byte $_lastOffset when the '
      'server is back.]\x1b[0m\r\n',
    );
    // A server on another machine comes back when this client's link to it
    // does (the data client keeps dialling it): reattach then.
    final next = Completer<void>();
    final waiting = SharedHostLinks.opened(access).listen((_) {
      if (!next.isCompleted) next.complete();
    });
    await Future.any([next.future, _gone.future]);
    await waiting.cancel();
    if (_disposed || _exited || _link != null) return;
    if (await _dial(await access.deployment(), redialing: true)) return;
    unawaited(_redial());
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
    // A terminal started from a pane at the session's grid starts at the view's.
    final fit = drawsAtSessionGrid ? viewGrid : null;
    final width = fit?.$1 ?? (terminal.viewWidth > 0 ? terminal.viewWidth : 80);
    final height =
        fit?.$2 ?? (terminal.viewHeight > 0 ? terminal.viewHeight : 24);
    final resumeFrom = _lastOffset;
    // A new flow at the server keeps no wish of this pane's.
    _toldGrid = null;
    HostPaneLink? link;
    try {
      // One link per server, every pane a ref on it (slice 5e).
      link = HostPaneLink.on(
        await SharedHostLinks.linkTo(access, deployment: deployment),
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
        redialing: redialing,
      );
      final skip = _skipsReplay(attachment, resumeFrom);
      if (skip) {
        _discardRemaining = attachment.totalBytes - attachment.replayFromOffset;
      }
      if (drawsAtSessionGrid) {
        // Before a byte is ingested: the screen that follows is drawn at it.
        _followSessionGrid(
          link,
          attachment.columns,
          attachment.rows,
          holds: attachment.holdsWriteToken,
        );
      } else {
        // Read now, not from `width`: the layout can land while the attach is
        // out.
        link.matchGrid(attachment, terminal.viewWidth, terminal.viewHeight);
      }
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
      final live = link;
      _presenceSubscription = live.presence.listen((told) {
        _presence.value = told;
        if (drawsAtSessionGrid) {
          _followSessionGrid(live, told.columns, told.rows, holds: told.mine);
        }
      });
      _refusals = link.refusedWrites.listen(
        (_) => _refusedAt.value = DateTime.now(),
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
      _logger.error('The Karmashala server refused pane $id: $e');
      _fail('The Karmashala server could not start this pane: $e');
      return false;
    }
  }

  /// Reattaches from the last offset this pane rendered. A pane with an
  /// [opener] asks the server for its terminal once, first — the server
  /// starts it, or answers the one already running under this pane's id
  /// (and replaces an ended record: an agent quit with Ctrl-C twice is run
  /// again, not reattached to its corpse). A redial, or a pane that only
  /// attaches, never starts anything: a session that is gone ends the pane.
  Future<HostAttachment> _attachOrOpen(
    HostPaneLink link,
    int width,
    int height,
    int sinceOffset, {
    required bool redialing,
  }) async {
    var fresh = false;
    final open = opener;
    if (open != null && !redialing && !_opened) {
      final opening = await open(width, height);
      _opened = true;
      if (opening.sessionId != sessionId) {
        throw HostLinkException(
          'the server started ${opening.sessionId}, not $sessionId',
        );
      }
      if (opening.shellIntegration) _recordCommandBlocks();
      if (opening.adopted) _sayAdopted();
      fresh = !opening.adopted;
    }
    try {
      final attachment = await link.attachSession(
        sessionId: sessionId,
        sinceOffset: sinceOffset,
        // A claim at attach takes the session to this pane's grid; a pane at
        // the session's takes the input only by typing.
        claimWrite: !drawsAtSessionGrid,
        // A pane with nothing of a running session yet asks for its screen:
        // the program's relative redraws replayed onto an empty one stack up.
        // A session started just now has written next to nothing, and its
        // bytes go under the restored history rather than resetting it.
        screenGrid: sinceOffset == 0 && !fresh ? (width, height) : null,
      );
      _resumed = !fresh;
      return attachment;
    } on HostLinkException catch (e) {
      // Only the server saying there is no such session ends the pane here.
      // A timeout or any other refusal may mean the session is there.
      if (e.code != ProtocolErrorCode.unknownSession) rethrow;
      throw const _SessionGone();
    }
  }

  /// Whether this pane has asked the server for its terminal already: a
  /// redial reattaches, it never asks again.
  var _opened = false;

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
  Future<void> endHostedSession() => _endSession();

  /// Ends the session for good: at the server's terminals when this pane
  /// has a [closer], so every client is told; else over the host link.
  Future<void> _endSession() {
    final close = closer;
    if (close != null) return close();
    return _link?.closeSession(sessionId) ?? Future<void>.value();
  }

  @override
  String get keptBy => 'the Karmashala server';

  /// Whether this pane attached to a session that already existed. It decides
  /// what an immediate end means: one we opened and that ended is a command
  /// that finished, one we merely found is a leftover to clear away.
  var _resumed = false;

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
      unawaited(_endSession().catchError((Object _) {}));
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
    _gone.complete();
    _recorder?.sourceEnded();
    _recorder = null;
    _typer.dispose();
    _liveness.value = PaneLiveness.exited;
    _liveness.dispose();
    _cwd.dispose();

    unawaited(_output?.cancel());
    unawaited(_notices?.cancel());
    unawaited(_presenceSubscription?.cancel());
    unawaited(_refusals?.cancel());
    _presence.dispose();
    _atSessionGrid.dispose();
    _refusedAt.dispose();
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

/// A redial found the host holding no session of this pane's id.
class _SessionGone implements Exception {
  const _SessionGone();
}
