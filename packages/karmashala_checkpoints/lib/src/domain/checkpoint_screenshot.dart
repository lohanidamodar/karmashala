/// What a checkpoint screenshot was taken of.
enum CheckpointScreenshotSource {
  browser,
  device;

  static CheckpointScreenshotSource? parse(String? value) =>
      values.where((s) => s.name == value).firstOrNull;
}

/// A picture of the running thing, filed against the checkpoint whose working
/// tree it showed. The PNG is a file; the row says where.
class CheckpointScreenshot {
  const CheckpointScreenshot({
    required this.id,
    required this.checkpointId,
    required this.source,
    required this.size,
    required this.width,
    required this.height,
    required this.path,
    required this.capturedAt,
    this.sessionId,
    this.subject,
    this.label,
  });

  final String id;
  final String checkpointId;
  final String? sessionId;
  final CheckpointScreenshotSource source;

  /// What pairs two captures across checkpoints: a browser viewport's name
  /// (`compact`, `medium`, `expanded`, `current`) or a device's id.
  final String size;
  final int width;
  final int height;

  /// The page URL or the device's name.
  final String? subject;
  final String? label;
  final String path;
  final DateTime capturedAt;

  /// Whether [other] shows the same thing at the same size, so the two compare.
  bool pairsWith(CheckpointScreenshot other) =>
      other.source == source && other.size == size;

  Map<String, Object?> toJson() => {
    'id': id,
    'checkpointId': checkpointId,
    if (sessionId != null) 'sessionId': sessionId,
    'source': source.name,
    'size': size,
    'width': width,
    'height': height,
    if (subject != null) 'subject': subject,
    if (label != null) 'label': label,
    'path': path,
    'capturedAt': capturedAt.toIso8601String(),
  };
}
