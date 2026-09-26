import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../protocol/frame.dart';
import '../protocol/messages.dart';
import '../protocol/wire.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';

/// A client's data API on a host, over the host protocol: its own
/// connection, saying `hello` and never `watch`, so it can be dialled before
/// anything else the client does and marks no session lost.
class HostDataLink implements DataEndpoint {
  HostDataLink._(this._connection);

  final HostConnection _connection;
  final _parser = FrameParser();
  final _changes = StreamController<DataChanges>();
  final _pending = <int, _Pending>{};
  final _done = Completer<void>();
  final _welcome = Completer<HostMessage>();
  StreamSubscription<List<int>>? _incoming;
  var _lastId = 0;

  /// What the host said about itself on the handshake.
  late final WelcomeMessage welcome;

  /// Null when nothing is listening at [socketPath]. Throws [DataRefused]
  /// ([DataRefusalCode.unavailable]) when something answers but refuses the
  /// handshake — another protocol — or does not answer in [answerWithin].
  static Future<HostDataLink?> connect(
    String socketPath, {
    String clientId = 'karmashala-data',
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
    return over(
      SocketHostConnection(socket, socketPath),
      clientId: clientId,
      answerWithin: answerWithin,
    );
  }

  static Future<HostDataLink> over(
    HostConnection connection, {
    String clientId = 'karmashala-data',
    Duration answerWithin = const Duration(seconds: 10),
  }) async {
    final link = HostDataLink._(connection);
    try {
      await link._start(clientId, answerWithin);
    } on Object {
      await link.close();
      rethrow;
    }
    return link;
  }

  Future<void> _start(String clientId, Duration within) async {
    _incoming = _connection.incoming.listen(
      _onBytes,
      onError: (Object error) => _end('$error'),
      onDone: () => _end('the Karmashala server closed the link'),
      cancelOnError: true,
    );
    _connection.add(
      HelloMessage(requestId: 1, clientId: clientId).toFrame().encode(),
    );
    final HostMessage answer;
    try {
      answer = await _welcome.future.timeout(within);
    } on TimeoutException {
      throw const DataRefused.unavailable(
        'the Karmashala server did not answer',
      );
    }
    if (answer is ErrorMessage) throw DataRefused.unavailable(answer.message);
    welcome = answer as WelcomeMessage;
  }

  @override
  Stream<DataChanges> get changes => _changes.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<DataReply<R>> send<R>(DataRequest<R> request) {
    if (_done.isCompleted) {
      return Future.error(
        const DataRefused.unavailable(
          'the link to the Karmashala server is closed',
        ),
      );
    }
    final id = ++_lastId;
    final pending = _Pending<R>(request);
    _pending[id] = pending;
    try {
      _connection.add(
        DataRequestMessage(
          DataEnvelope.request(id, request),
        ).toFrame().encode(),
      );
    } on Object {
      _pending.remove(id);
      return Future.error(
        const DataRefused.unavailable(
          'the link to the Karmashala server is closed',
        ),
      );
    }
    return pending.answer.future;
  }

  void _onBytes(List<int> chunk) {
    final List<Frame> frames;
    try {
      frames = _parser.add(chunk);
    } on FrameFormatException catch (e) {
      _end(e.message);
      return;
    }
    for (final frame in frames) {
      final HostMessage message;
      try {
        message = decodeMessage(frame);
      } on WireFormatException {
        continue;
      }
      _onMessage(message);
    }
  }

  void _onMessage(HostMessage message) {
    switch (message) {
      case WelcomeMessage() || ErrorMessage() when !_welcome.isCompleted:
        _welcome.complete(message);
      case DataAnswerMessage(:final envelope):
        final id = DataEnvelope.answerId(envelope);
        if (id != null) _pending.remove(id)?.complete(envelope);
      case DataChangesMessage(:final envelope):
        try {
          if (!_changes.isClosed) {
            _changes.add(DataEnvelope.readChanges(envelope));
          }
        } on Object {
          // A batch this build cannot read is skipped; the next snapshot
          // after a redial is whole.
        }
      default:
        break;
    }
  }

  void _end(String reason) {
    if (!_welcome.isCompleted) {
      _welcome.completeError(DataRefused.unavailable(reason));
    }
    for (final pending in _pending.values) {
      pending.fail(DataRefused.unavailable(reason));
    }
    _pending.clear();
    if (!_changes.isClosed) unawaited(_changes.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    await _incoming?.cancel();
    _incoming = null;
    _end('closed');
    await _connection.close();
  }
}

final class _Pending<R> {
  _Pending(this.request);

  final DataRequest<R> request;
  final answer = Completer<DataReply<R>>();

  void complete(Map<String, Object?> envelope) {
    try {
      answer.complete(DataEnvelope.readAnswer(envelope, request));
    } on Object catch (error) {
      answer.completeError(error);
    }
  }

  void fail(DataRefused refusal) {
    if (!answer.isCompleted) answer.completeError(refusal);
  }
}
