import 'dart:async';
import 'dart:io';

import '../domain/session_lifecycle.dart';
import '../domain/session_registry.dart';
import '../protocol/frame.dart';
import '../protocol/messages.dart';
import '../pty/process_alive.dart';
import 'host_paths.dart';

/// The hand-operated half of the host: what somebody sitting on the machine
/// needs when the app is not there. `attach` is a byte proxy for the app;
/// these speak the protocol themselves and print.
class HostClient {
  HostClient._(this._socket, this._messages);

  final Socket _socket;
  final Stream<HostMessage> _messages;

  /// What the host said about itself on the handshake. Its pid comes from here
  /// rather than from the lock file, which on Windows it holds exclusively and
  /// nobody else can read.
  late final WelcomeMessage welcome;

  /// Null when nothing is listening — the caller says so in its own words.
  static Future<HostClient?> connect(
    String socketPath, {
    Duration answerWithin = const Duration(seconds: 10),
  }) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    } on SocketException {
      return null;
    }
    final parser = FrameParser();
    final messages = socket
        .expand((chunk) => parser.add(chunk))
        .map(decodeMessage)
        .asBroadcastStream();
    final client = HostClient._(socket, messages);
    client._send(const HelloMessage(requestId: 1, clientId: 'karmashala-cli'));
    try {
      client.welcome = await client._expect<WelcomeMessage>(
        within: answerWithin,
      );
    } on HostClientRefusal {
      socket.destroy();
      rethrow;
    }
    return client;
  }

  void _send(HostMessage message) => _socket.add(message.toFrame().encode());

  /// The next message of this type — that [where] accepts, when given — or
  /// the host's refusal, or a bound. A hand-run command must not sit on a
  /// socket that stopped answering.
  Future<T> _expect<T extends HostMessage>({
    Duration within = const Duration(seconds: 10),
    bool Function(T message)? where,
  }) {
    final answer = Completer<T>();
    late StreamSubscription<HostMessage> subscription;
    subscription = _messages.listen(
      (message) {
        if (answer.isCompleted) return;
        if (message is T && (where == null || where(message))) {
          answer.complete(message);
        } else if (message is ErrorMessage) {
          answer.completeError(HostClientRefusal(message.message));
        } else {
          return;
        }
        unawaited(subscription.cancel());
      },
      onDone: () {
        if (!answer.isCompleted) {
          answer.completeError(
            const HostClientRefusal('the host closed first'),
          );
        }
      },
      onError: (Object e) {
        if (!answer.isCompleted) answer.completeError(HostClientRefusal('$e'));
      },
    );
    return answer.future.timeout(
      within,
      onTimeout: () => throw const HostClientRefusal('the host did not answer'),
    );
  }

  Future<List<SessionSummary>> list() async {
    _send(const ListMessage(2));
    return (await _expect<SessionsMessage>()).summaries;
  }

  Future<int?> end(String sessionId) async {
    _send(CloseMessage(3, sessionId));
    return (await _expect<ClosedMessage>()).exitCode;
  }

  var _lastRequestId = 10;

  /// Opens a pairing window at the host, as the desktop's dialog does.
  /// Throws [HostClientRefusal] with the host's reason when it will not.
  Future<PairedMessage> pair({
    required int capabilities,
    String relay = '',
    String label = '',
  }) {
    final requestId = ++_lastRequestId;
    // Listening before sending: the answer can come back before `_expect`
    // would otherwise subscribe.
    final answer = _expect<PairedMessage>(
      where: (message) => message.requestId == requestId,
    );
    _send(
      PairMessage(
        requestId: requestId,
        capabilities: capabilities,
        relay: relay,
        label: label,
      ),
    );
    return answer;
  }

  /// How the window [pair] opened under [requestId] ended: a device id, or
  /// the host's reason. Throws [HostClientRefusal] when nothing is said
  /// [within].
  Future<CompanionEventMessage> pairingEnded(
    int requestId, {
    required Duration within,
  }) => _expect<CompanionEventMessage>(
    within: within,
    where: (message) =>
        message.kind == CompanionEventKind.pairingEnded &&
        message.requestId == requestId,
  );

  /// Asks the host one administrative question (`ServerMethod`). Throws
  /// [HostClientRefusal] with its answer when it refuses.
  Future<Map<String, Object?>> call(
    String method, {
    Map<String, Object?> arguments = const {},
    Duration within = const Duration(seconds: 10),
  }) async {
    final requestId = ++_lastRequestId;
    final answer = _expect<ServerResultMessage>(
      within: within,
      where: (message) => message.requestId == requestId,
    );
    _send(
      ServerCallMessage(
        requestId: requestId,
        method: method,
        arguments: arguments,
      ),
    );
    final result = await answer;
    final refused = result.message;
    if (refused != null) throw HostClientRefusal(refused);
    return result.result ?? const {};
  }

  Future<void> close() async => _socket.destroy();
}

class HostClientRefusal implements Exception {
  const HostClientRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `karmashala_host list`.
Future<int> runList({IOSink? out, IOSink? err, HostPaths? paths}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final resolved = paths ?? HostPaths.resolve();
  final client = await HostClient.connect(resolved.socketPath);
  if (client == null) {
    errSink.writeln('karmashala_host list: no host at ${resolved.socketPath}');
    return 5;
  }
  try {
    final sessions = await client.list();
    if (sessions.isEmpty) {
      sink.writeln('no sessions');
      return 0;
    }
    sink.writeln(formatSessions(sessions));
    return 0;
  } on HostClientRefusal catch (e) {
    errSink.writeln('karmashala_host list: $e');
    return 6;
  } finally {
    await client.close();
  }
}

/// `karmashala_host end <id>`.
Future<int> runEnd(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  if (args.isEmpty) {
    errSink.writeln('karmashala_host end: name a session (see `list`)');
    return 2;
  }
  final resolved = paths ?? HostPaths.resolve();
  final client = await HostClient.connect(resolved.socketPath);
  if (client == null) {
    errSink.writeln('karmashala_host end: no host at ${resolved.socketPath}');
    return 5;
  }
  try {
    final code = await client.end(args.first);
    // Null is a real answer: the child was signalled and never reaped.
    sink.writeln('ended ${args.first}${code == null ? '' : ' (exit $code)'}');
    return 0;
  } on HostClientRefusal catch (e) {
    errSink.writeln('karmashala_host end: $e');
    return 6;
  } finally {
    await client.close();
  }
}

/// `karmashala_host stop` — the serve itself, by the pid in its own lock.
/// Every session it holds goes with it, so it says how many first.
Future<int> runStop(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Duration grace = const Duration(seconds: 5),
  Duration answerWithin = const Duration(seconds: 10),
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final resolved = paths ?? HostPaths.resolve();
  final force = args.contains('--force') || args.contains('-f');

  HostClient? client;
  HostClientRefusal? silent;
  try {
    client = await HostClient.connect(
      resolved.socketPath,
      answerWithin: answerWithin,
    );
  } on HostClientRefusal catch (e) {
    // Took the connection and never welcomed it: a host wedged in a syscall.
    silent = e;
  }
  var held = 0;
  int? pid;
  if (silent != null && !force) {
    errSink.writeln(
      'karmashala_host stop: the host at ${resolved.socketPath} would not '
      'answer ($silent), so what it holds is unknown. Pass --force to stop it '
      'by the pid in ${resolved.lockPath}.',
    );
    return 3;
  }
  if (client != null) {
    pid = client.welcome.pid;
    try {
      held = (await client.list()).where((s) => !s.lifecycle.hasEnded).length;
    } on HostClientRefusal {
      held = 0;
    } finally {
      await client.close();
    }
  }
  if (held > 0 && !force) {
    errSink.writeln(
      'karmashala_host stop: $held session(s) are still running. '
      'End them first, or pass --force to take them down with the host.',
    );
    return 3;
  }

  // A host that would not answer is exactly the one worth stopping, so the
  // lock file is the fallback rather than the first choice.
  pid ??= _lockPid(resolved.lockPath);
  if (pid == null) {
    errSink.writeln(
      'karmashala_host stop: nothing answering at ${resolved.socketPath}, '
      'and no pid recorded at ${resolved.lockPath}',
    );
    return 5;
  }
  // An interactive shell ignores SIGTERM and so, under load, does the host;
  // the escalation is the same one `HostSession.terminate` makes.
  Process.killPid(pid);
  final deadline = DateTime.now().add(grace);
  while (DateTime.now().isBefore(deadline)) {
    if (!processIsAlive(pid)) {
      sink.writeln('stopped pid $pid');
      return 0;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  Process.killPid(pid, ProcessSignal.sigkill);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (processIsAlive(pid)) {
    errSink.writeln('karmashala_host stop: pid $pid would not go');
    return 6;
  }
  sink.writeln('stopped pid $pid (it ignored the first signal)');
  return 0;
}

int? _lockPid(String lockPath) {
  try {
    final text = File(lockPath).readAsStringSync().trim();
    return int.tryParse(text);
  } on FileSystemException {
    return null;
  }
}

/// One line per session, widest column first so ids line up.
String formatSessions(List<SessionSummary> sessions) {
  final rows = <List<String>>[
    ['SESSION', 'PID', 'SIZE', 'STATE', 'COMMAND'],
    for (final s in sessions)
      [
        s.id,
        '${s.pid}',
        _bytes(s.totalBytes),
        _state(s.lifecycle),
        s.argv.join(' '),
      ],
  ];
  final widths = List<int>.generate(
    4,
    (i) => rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b),
  );
  return rows
      .map((r) {
        final head = [
          for (var i = 0; i < 4; i++) r[i].padRight(widths[i]),
        ].join('  ');
        return '$head  ${r[4]}'.trimRight();
      })
      .join('\n');
}

String _state(SessionLifecycle lifecycle) => switch (lifecycle) {
  SessionRunning() => 'running',
  SessionExited(:final exitCode) => 'exit $exitCode',
  SessionEndedWithoutCode() => 'ended',
};

String _bytes(int total) {
  if (total < 1024) return '${total}B';
  if (total < 1024 * 1024) return '${(total / 1024).toStringAsFixed(0)}K';
  return '${(total / (1024 * 1024)).toStringAsFixed(1)}M';
}
