import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';
import 'connection_channel.dart';

/// A client's data API on a host, over the host protocol: on the client's
/// one link ([onLink], slice 5e), or a connection of its own ([connect],
/// [over]) that says `hello` and never `watch`, so it marks no session lost.
class HostDataLink implements DataEndpoint {
  HostDataLink._(this._link, this._owns);

  final HostClientLink _link;
  final bool _owns;
  final _changes = StreamController<DataChanges>();
  final _pending = <int, _Pending>{};
  final _done = Completer<void>();
  StreamSubscription<HostMessage>? _messages;
  var _lastId = 0;

  /// What the host said about itself on the handshake.
  WelcomeMessage get welcome => _link.welcome;

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
    final HostClientLink link;
    try {
      link = await HostClientLink.open(
        ConnectionChannel(connection),
        clientId: clientId,
        features: 0,
        bound: answerWithin,
      );
    } on HostLinkException catch (error) {
      throw DataRefused.unavailable(
        error.timedOut ? 'the Karmashala server did not answer' : error.message,
      );
    }
    return HostDataLink._(link, true).._listen();
  }

  /// The data API on a client's shared [link]; [close] leaves the link up.
  static HostDataLink onLink(HostClientLink link) =>
      HostDataLink._(link, false).._listen();

  void _listen() {
    _messages = _link.messages.listen(_onMessage);
    unawaited(_link.done.then((_) => _end(_link.closeReason ?? 'closed')));
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
    _link.send(DataRequestMessage(DataEnvelope.request(id, request)));
    return pending.answer.future;
  }

  final _streams = <int, StreamController<DataStreamItems>>{};
  var _lastStreamId = 0;

  @override
  Stream<DataStreamItems> openStream(String source, String key) {
    late final StreamController<DataStreamItems> controller;
    final id = ++_lastStreamId;
    controller = StreamController<DataStreamItems>(
      onListen: () {
        if (_done.isCompleted) {
          controller
            ..addError(
              const DataRefused.unavailable(
                'the link to the Karmashala server is closed',
              ),
            )
            ..close();
          return;
        }
        _streams[id] = controller;
        _link.send(
          DataStreamOpenMessage(DataStreamEnvelope.open(id, source, key)),
        );
      },
      onCancel: () {
        if (_streams.remove(id) != null) {
          _link.send(DataStreamCloseMessage(DataStreamEnvelope.close(id)));
        }
      },
    );
    return controller.stream;
  }

  void _onMessage(HostMessage message) {
    switch (message) {
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
      case DataStreamItemsMessage(:final envelope):
        final batch = DataStreamEnvelope.readItems(envelope);
        if (batch == null) break;
        final controller = _streams[batch.streamId];
        if (controller == null) break;
        controller.add(batch);
        if (batch.ended != null) {
          _streams.remove(batch.streamId);
          unawaited(controller.close());
        }
      default:
        break;
    }
  }

  void _end(String reason) {
    if (_done.isCompleted) return;
    unawaited(_messages?.cancel());
    _messages = null;
    for (final pending in _pending.values) {
      pending.fail(DataRefused.unavailable(reason));
    }
    _pending.clear();
    final streams = [..._streams.values];
    _streams.clear();
    for (final stream in streams) {
      stream.add(DataStreamItems(0, const [], ended: reason));
      unawaited(stream.close());
    }
    if (!_changes.isClosed) unawaited(_changes.close());
    _done.complete();
  }

  @override
  Future<void> close() async {
    _end('closed');
    if (_owns) await _link.close();
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
