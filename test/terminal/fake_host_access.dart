import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_host/protocol.dart';

/// A machine whose session host answers, with the reading the test chooses.
/// Nothing here dials anything: the pane only ever asks for a reading and a
/// channel.
class PaneAccess implements HostSessionAccess {
  PaneAccess(this._deployment);

  HostDeployment _deployment;
  final channels = <ScriptedHostChannel>[];
  final execs = <String>[];
  final _reconnects = StreamController<void>.broadcast();

  /// The machine's sessions, surviving a link the way real ones do.
  final liveSessions = <String>{};

  /// Records the host keeps for sessions whose process has exited.
  final endedSessions = <String>{};

  /// What tmux on that machine is holding, and whether it will say. Unknown is
  /// a third answer, not a silent "no" — a pane treats it as a session it must
  /// not walk away from.
  final tmuxSessions = <String>{};
  var tmuxUnknown = false;
  var tmuxAsks = 0;

  /// What the host answers an attach with instead of looking the session up.
  ProtocolErrorCode? attachRefusal;

  /// A host built before `openWithout`: it cannot read that frame, answers
  /// request 0 with `badRequest` and hangs up, as an older `serve` does.
  var predatesWithholding = false;

  /// What a *reattach* says the session has produced so far. Zero unless a test
  /// is about what a pane does with a session that already has history.
  int resumedTotalBytes = 0;
  var deploymentAsks = 0;

  /// The pid the host gives in its welcome. Changed by a test to stand for a
  /// host that died and was replaced by another.
  var hostPid = 11;
  Object? deploymentError;

  @override
  String get address => 'fake.example';

  @override
  Stream<void> get reconnected => _reconnects.stream;

  @override
  Future<HostDeployment> deployment() async {
    deploymentAsks++;
    final failure = deploymentError;
    if (failure != null) throw failure;
    return _deployment;
  }

  /// What this machine answers when asked for its login shell. Null is a real
  /// answer — the machine that would not say.
  String? shell = '/usr/bin/zsh';
  var shellAsks = 0;

  @override
  Future<String?> loginShell() async {
    shellAsks++;
    return shell;
  }

  @override
  Future<bool?> hasTmuxSession(String name) async {
    tmuxAsks++;
    return tmuxUnknown ? null : tmuxSessions.contains(name);
  }

  @override
  Future<RemoteChannel> exec(String command) async {
    execs.add(command);
    final channel = ScriptedHostChannel(
      liveSessions,
      endedSessions: endedSessions,
      resumedTotalBytes: resumedTotalBytes,
      attachRefusal: attachRefusal,
      predatesWithholding: predatesWithholding,
      hostPid: hostPid,
    );
    channels.add(channel);
    return channel;
  }

  /// The pool re-established the connection.
  void reconnect({HostDeployment? nowReporting}) {
    if (nowReporting != null) _deployment = nowReporting;
    _reconnects.add(null);
  }

  Future<void> dispose() => _reconnects.close();
}

class ScriptedHostChannel implements RemoteChannel {
  ScriptedHostChannel(
    this.liveSessions, {
    Set<String>? endedSessions,
    this.resumedTotalBytes = 0,
    this.attachRefusal,
    this.predatesWithholding = false,
    this.hostPid = 11,
  }) : endedSessions = endedSessions ?? <String>{};

  final int hostPid;

  /// Shared with the machine: sessions whose process exited, still listed.
  final Set<String> endedSessions;

  final ProtocolErrorCode? attachRefusal;
  final bool predatesWithholding;

  /// The host starts an opened session but its reply never arrives.
  var loseOpenReply = false;

  /// What a reattach reports as this session's absolute total.
  final int resumedTotalBytes;

  /// Shared with the machine, so a session opened on one link is found by the
  /// next one — which is the behaviour a reattach depends on.
  final Set<String> liveSessions;

  final _toApp = StreamController<Uint8List>.broadcast();
  final _parser = FrameParser();
  final received = <HostMessage>[];
  var closed = false;

  @override
  Stream<Uint8List> get stdout => _toApp.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      received.add(message);
      switch (message) {
        case HelloMessage(:final requestId):
          push(
            WelcomeMessage(
              requestId: requestId,
              protocolVersion: kProtocolVersion,
              hostVersion: '0.1.0',
              operatingSystem: 'linux',
              architecture: 'x64',
              ptyLibrary: 'libc.so.6',
              pid: hostPid,
              startedAt: DateTime.utc(2026),
              observedAt: DateTime.utc(2026),
            ),
          );
        case ListMessage(:final requestId):
          push(
            SessionsMessage(requestId, [
              for (final id in {...liveSessions, ...endedSessions})
                SessionSummary(
                  id: id,
                  argv: const ['agent'],
                  workingDirectory: null,
                  pid: 11,
                  columns: 80,
                  rows: 24,
                  startedAt: DateTime.utc(2026),
                  observedAt: DateTime.utc(2026),
                  totalBytes: resumedTotalBytes,
                  firstAvailableOffset: 0,
                  lifecycle: endedSessions.contains(id)
                      ? SessionExited(0, DateTime.utc(2026))
                      : const SessionRunning(),
                  writeHolder: null,
                ),
            ]),
          );
        case CloseMessage(:final requestId, :final sessionId):
          liveSessions.remove(sessionId);
          endedSessions.remove(sessionId);
          push(ClosedMessage(requestId, sessionId, 0));
        case AttachMessage(:final requestId, :final sessionId)
            when endedSessions.contains(sessionId):
          // What the real host does: attach to the kept record, then say it
          // already ended.
          push(_attached(requestId, sessionId));
          push(
            ExitedMessage(
              sessionRef: 1,
              sessionId: sessionId,
              exitCode: 0,
              reason: 'exited',
              observedAt: DateTime.utc(2026),
            ),
          );
        case AttachMessage(:final requestId, :final sessionId):
          if (attachRefusal != null) {
            push(
              ErrorMessage(
                requestId,
                attachRefusal!,
                'refused: ${attachRefusal!.name}',
              ),
            );
            break;
          }
          if (!liveSessions.contains(sessionId)) {
            // The pane must fall through to `open` on its first run.
            push(
              ErrorMessage(
                requestId,
                ProtocolErrorCode.unknownSession,
                'no session "$sessionId"',
              ),
            );
            break;
          }
          push(_attached(requestId, sessionId));
        case OpenMessage(:final removedEnvironment)
            when predatesWithholding && removedEnvironment.isNotEmpty:
          push(
            const ErrorMessage(
              0,
              ProtocolErrorCode.badRequest,
              'unknown message type 0x14',
            ),
          );
          unawaited(close());
        case OpenMessage(:final requestId, :final sessionId)
            when liveSessions.contains(sessionId):
          push(
            ErrorMessage(
              requestId,
              ProtocolErrorCode.sessionExists,
              'session "$sessionId" already exists',
            ),
          );
        case OpenMessage(
          :final requestId,
          :final sessionId,
          :final columns,
          :final rows,
        ):
          liveSessions.add(sessionId);
          if (loseOpenReply) break;
          push(
            AttachedMessage(
              requestId: requestId,
              sessionRef: 1,
              sessionId: sessionId,
              columns: columns,
              rows: rows,
              replayFromOffset: 0,
              droppedBytes: 0,
              totalBytes: 0,
              holdsWriteToken: true,
              writeHolder: 'pane-p1',
              observedAt: DateTime.utc(2026),
            ),
          );
        default:
          break;
      }
    }
  }

  AttachedMessage _attached(int requestId, String sessionId) => AttachedMessage(
    requestId: requestId,
    sessionRef: 1,
    sessionId: sessionId,
    columns: 80,
    rows: 24,
    replayFromOffset: 0,
    droppedBytes: 0,
    totalBytes: resumedTotalBytes,
    holdsWriteToken: true,
    writeHolder: 'pane-p1',
    observedAt: DateTime.utc(2026),
  );

  /// What the host says, unprompted.
  void push(HostMessage message) {
    if (!_toApp.isClosed) _toApp.add(message.toFrame().encode());
  }

  void pushOutput(int offset, String text) =>
      push(OutputMessage(1, offset, Uint8List.fromList(text.codeUnits)));

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    closed = true;
    if (!_toApp.isClosed) await _toApp.close();
  }

  T only<T extends HostMessage>() => received.whereType<T>().single;
  Iterable<T> all<T extends HostMessage>() => received.whereType<T>();
}

/// The reading a machine with a working host gives.
HostDeployment readyDeployment({bool restarted = false}) => HostDeployment(
  status: HostDeploymentStatus.ready,
  observedAt: DateTime.utc(2026, 9, 8, 14, 0),
  reason: 'answering',
  // Absolute, the way a deploy that resolved the remote home reports it.
  remotePath: '/home/me/.karmashala/bin/karmashala_host-0.1.0-linux-x64',
  hostVersion: '0.1.0',
  protocolVersion: kProtocolVersion,
  restartedByUs: restarted,
);
