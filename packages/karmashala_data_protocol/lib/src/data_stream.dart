/// The source name of one Flutter app's debug console; the key is its app id
/// and each item an `AppLogRecord` as JSON.
const String kFlutterLogsStream = 'flutter.logs';

/// One batch of a live stream a client opened: items oldest first, and how
/// many were dropped before them because the client fell behind the
/// server's bounded buffer. [ended] says the source went away (the stream
/// ends after this batch).
final class DataStreamItems {
  const DataStreamItems(
    this.streamId,
    this.items, {
    this.dropped = 0,
    this.ended,
  });

  final int streamId;
  final List<Object?> items;
  final int dropped;
  final String? ended;
}

/// How live streams travel, one JSON object each, whatever carries them —
/// host frames today (0x3b–0x3d), a companion frame later:
///
/// - open (client → server): `{streamId, source, key}`
/// - items (server → client): `{streamId, items: [...], dropped?, ended?}`
/// - close (client → server): `{streamId}`
///
/// The first batch after an open is the source's backlog, then what arrives.
abstract final class DataStreamEnvelope {
  static Map<String, Object?> open(int streamId, String source, String key) => {
    'streamId': streamId,
    'source': source,
    'key': key,
  };

  static ({int streamId, String source, String key})? readOpen(
    Map<String, Object?> json,
  ) {
    final id = json['streamId'];
    final source = json['source'];
    final key = json['key'];
    if (id is! int || source is! String || key is! String) return null;
    return (streamId: id, source: source, key: key);
  }

  static Map<String, Object?> items(DataStreamItems batch) => {
    'streamId': batch.streamId,
    'items': batch.items,
    if (batch.dropped > 0) 'dropped': batch.dropped,
    'ended': ?batch.ended,
  };

  static DataStreamItems? readItems(Map<String, Object?> json) {
    final id = json['streamId'];
    final items = json['items'];
    if (id is! int || items is! List) return null;
    return DataStreamItems(
      id,
      List<Object?>.unmodifiable(items),
      dropped: json['dropped'] as int? ?? 0,
      ended: json['ended'] as String?,
    );
  }

  static Map<String, Object?> close(int streamId) => {'streamId': streamId};

  static int? readClose(Map<String, Object?> json) => json['streamId'] as int?;
}
