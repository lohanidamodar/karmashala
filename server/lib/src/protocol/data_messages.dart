part of 'messages.dart';

// The data API (protocol 11): a client's reads and writes of the server's
// data, and the changes other clients made. Each frame carries one
// `DataEnvelope` JSON object from `karmashala_data_protocol`, which knows the
// requests; this layer only carries them, so another transport can carry the
// same envelopes.

/// client → host: one data request, `{id, kind, arguments}`.
class DataRequestMessage extends HostMessage {
  const DataRequestMessage(this.envelope);

  final Map<String, Object?> envelope;

  @override
  Frame toFrame() => _jsonFrame(MessageType.dataRequest, envelope);

  static DataRequestMessage decode(Frame frame) =>
      DataRequestMessage(_jsonPayload(frame, 'data request'));
}

/// host → client: how one data request ended, `{id, revision, result}` or
/// `{id, refusal}`.
class DataAnswerMessage extends HostMessage {
  const DataAnswerMessage(this.envelope);

  final Map<String, Object?> envelope;

  @override
  Frame toFrame() => _jsonFrame(MessageType.dataAnswer, envelope);

  static DataAnswerMessage decode(Frame frame) =>
      DataAnswerMessage(_jsonPayload(frame, 'data answer'));
}

/// host → client: what another client's write changed, `{revision,
/// changes}` — only on a link that subscribed.
class DataChangesMessage extends HostMessage {
  const DataChangesMessage(this.envelope);

  final Map<String, Object?> envelope;

  @override
  Frame toFrame() => _jsonFrame(MessageType.dataChanges, envelope);

  static DataChangesMessage decode(Frame frame) =>
      DataChangesMessage(_jsonPayload(frame, 'data changes'));
}

/// client → host: open a live stream, `{streamId, source, key}`.
class DataStreamOpenMessage extends HostMessage {
  const DataStreamOpenMessage(this.envelope);

  final Map<String, Object?> envelope;

  @override
  Frame toFrame() => _jsonFrame(MessageType.dataStreamOpen, envelope);

  static DataStreamOpenMessage decode(Frame frame) =>
      DataStreamOpenMessage(_jsonPayload(frame, 'data stream open'));
}

/// host → client: one batch of an open stream, `{streamId, items, dropped?,
/// ended?}`.
class DataStreamItemsMessage extends HostMessage {
  const DataStreamItemsMessage(this.envelope);

  final Map<String, Object?> envelope;

  @override
  Frame toFrame() => _jsonFrame(MessageType.dataStreamItems, envelope);

  static DataStreamItemsMessage decode(Frame frame) =>
      DataStreamItemsMessage(_jsonPayload(frame, 'data stream items'));
}

/// client → host: close a stream, `{streamId}`.
class DataStreamCloseMessage extends HostMessage {
  const DataStreamCloseMessage(this.envelope);

  final Map<String, Object?> envelope;

  @override
  Frame toFrame() => _jsonFrame(MessageType.dataStreamClose, envelope);

  static DataStreamCloseMessage decode(Frame frame) =>
      DataStreamCloseMessage(_jsonPayload(frame, 'data stream close'));
}

Frame _jsonFrame(MessageType type, Map<String, Object?> body) =>
    Frame(type, 0, (WireWriter()..str(jsonEncode(body))).take());

Map<String, Object?> _jsonPayload(Frame frame, String what) {
  final reader = WireReader(frame.payload);
  final body = _object(_decodeJson(reader.str()), what);
  reader.expectEnd();
  return body;
}
