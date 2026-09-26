part of 'messages.dart';

// Commands the server runs through the app (protocol 18): the one reach the
// server has no transport for of its own — an SSH box, dialled over the
// app's connection pool with the host-key trust a person gives there
// (`karmashala_ssh` deploys this server, so the server cannot depend on it).
// Detection and the account capture and switch on an SSH environment run
// their commands this way; everything else they do stays at the server.

/// client → host: "run SSH commands through me" — the one connection the
/// server sends [RunCallMessage]s to, until another says it or it hangs up.
class RunOfferMessage extends HostMessage {
  const RunOfferMessage();

  @override
  Frame toFrame() =>
      Frame(MessageType.runOffer, 0, (WireWriter()..str('{}')).take());

  static RunOfferMessage decode(Frame frame) => const RunOfferMessage();
}

/// host → client: run [command] (a `CommandRequest` as JSON) in environment
/// [environmentId] and answer [callId]. [command] may carry a file's text
/// on stdin — an account being switched to — so neither side logs it.
class RunCallMessage extends HostMessage {
  const RunCallMessage({
    required this.callId,
    required this.environmentId,
    required this.command,
  });

  final int callId;
  final String environmentId;
  final Map<String, Object?> command;

  @override
  Frame toFrame() => Frame(
    MessageType.runCall,
    0,
    (WireWriter()..str(
          jsonEncode({
            'callId': callId,
            'environmentId': environmentId,
            'command': command,
          }),
        ))
        .take(),
  );

  static RunCallMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'run call',
    );
    return RunCallMessage(
      callId: _required<int>(map, 'callId'),
      environmentId: _required<String>(map, 'environmentId'),
      command: _object(map['command'], 'run command'),
    );
  }

  @override
  String toString() => 'RunCallMessage($callId in $environmentId)';
}

/// client → host: how [callId] ended — the process's exit code and output,
/// or [error] when it could not be run at all.
class RunResultMessage extends HostMessage {
  const RunResultMessage.ran(
    this.callId, {
    required int this.exitCode,
    required String this.stdout,
    required String this.stderr,
  }) : error = null;

  const RunResultMessage.failed(this.callId, String this.error)
    : exitCode = null,
      stdout = null,
      stderr = null;

  final int callId;
  final int? exitCode;
  final String? stdout;
  final String? stderr;
  final String? error;

  @override
  Frame toFrame() => Frame(
    MessageType.runResult,
    0,
    (WireWriter()..str(
          jsonEncode({
            'callId': callId,
            'exitCode': ?exitCode,
            'stdout': ?stdout,
            'stderr': ?stderr,
            'error': ?error,
          }),
        ))
        .take(),
  );

  static RunResultMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'run result',
    );
    final callId = _required<int>(map, 'callId');
    final error = _optional<String>(map, 'error');
    if (error != null) return RunResultMessage.failed(callId, error);
    return RunResultMessage.ran(
      callId,
      exitCode: _required<int>(map, 'exitCode'),
      stdout: _optional<String>(map, 'stdout') ?? '',
      stderr: _optional<String>(map, 'stderr') ?? '',
    );
  }

  @override
  String toString() => 'RunResultMessage($callId)';
}
