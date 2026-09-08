import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala/src/features/ssh/data/host_deploy_target.dart';
import 'package:karmashala/src/features/ssh/data/host_session_access.dart';
import 'package:karmashala/src/features/ssh/domain/host_deployment.dart';
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
  var deploymentAsks = 0;
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

  @override
  Future<RemoteChannel> exec(String command) async {
    execs.add(command);
    final channel = ScriptedHostChannel(liveSessions);
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
  ScriptedHostChannel(this.liveSessions);

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
              pid: 11,
              startedAt: DateTime.utc(2026),
              observedAt: DateTime.utc(2026),
            ),
          );
        case AttachMessage(:final requestId, :final sessionId):
          if (!liveSessions.contains(sessionId)) {
            // The pane must fall through to `open` on its first run.
            push(
              ErrorMessage(requestId, ProtocolErrorCode.unknownSession, 'no session "$sessionId"'),
            );
            break;
          }
          push(_attached(requestId, sessionId));
        case OpenMessage(:final requestId, :final sessionId):
          liveSessions.add(sessionId);
          push(
            AttachedMessage(
              requestId: requestId,
              sessionRef: 1,
              sessionId: sessionId,
              columns: 80,
              rows: 24,
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
    totalBytes: 0,
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
}


/// The reading a machine with a working host gives.
HostDeployment readyDeployment({bool restarted = false}) => HostDeployment(
  status: HostDeploymentStatus.ready,
  observedAt: DateTime.utc(2026, 9, 8, 14, 0),
  reason: 'answering',
  remotePath: r'$HOME/.karmashala/bin/karmashala_host-0.1.0-linux-x64',
  hostVersion: '0.1.0',
  protocolVersion: kProtocolVersion,
  restartedByUs: restarted,
);
