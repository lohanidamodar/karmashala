/// One picture a session produced or was shown: a name, a time, and either a
/// file to draw or an honest reason there is none.
library;

/// How a picture got into the conversation: what the panel says when there is
/// no path, and whether [SessionMediaItem.path] needs translating.
enum SessionMediaOrigin {
  /// A tool call read an image file. The path is real and written in the
  /// *agent's* environment.
  read('Read'),

  /// A human put a picture into the conversation: base64 in the record and no
  /// path anywhere.
  pasted('Pasted'),

  /// A tool answered with a picture. Only `device_screenshot` also leaves a
  /// copy in temp, so the block in the record is the one source for all three.
  captured('Captured');

  const SessionMediaOrigin(this.label);

  final String label;
}

/// The extensions the scan writes and the preview opens — the same set
/// `looksLikeImagePath` accepts, or the file would be one nobody can see.
const Map<String, String> kMediaTypeExtensions = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/bmp': 'bmp',
};

/// The biggest single picture the panel will move to disk. Mirrors
/// `kMaxImagePreviewBytes`, kept here so `data/` does not depend on a widget.
const int kMaxSessionMediaBytes = 12 * 1024 * 1024;

/// How many pictures the panel keeps: a long session is unbounded and the
/// extracted copies are real files.
const int kSessionMediaCap = 60;

class SessionMediaItem {
  const SessionMediaItem({
    required this.id,
    required this.origin,
    required this.sequence,
    this.path,
    this.fromAgentEnvironment = false,
    this.toolName,
    this.at,
    this.bytes,
    this.problem,
    this.pasteId,
  });

  /// Stable for the life of the transcript: derived from where in the file the
  /// picture was recorded, which is why a copy is found again without decoding.
  final String id;

  final SessionMediaOrigin origin;

  /// Where in the transcript this was recorded — higher is newer. Sorted on
  /// rather than [at], because a line without a timestamp is common.
  final int sequence;

  /// The file to draw, or null when there is nothing drawable — see [problem].
  final String? path;

  /// Whether [path] was written by the agent and so needs translating
  /// (`/mnt/c/…` → `C:\…`). False for the scan's own copies.
  final bool fromAgentEnvironment;

  final String? toolName;

  final DateTime? at;

  /// The size of the picture, when it is known without decoding it.
  final int? bytes;

  /// Why there is no [path]. Set instead of dropping the item: a picture the
  /// panel cannot show is still one the session had.
  final String? problem;

  /// The `6` in `[Image #6]`, or null. Read out of `imagePasteIds`, never
  /// inferred from [sequence]; only a paste ever has one.
  final int? pasteId;

  /// The name to show: the file name where there is one, and what the item *is*
  /// where there is not.
  String get label => switch (origin) {
    SessionMediaOrigin.read => _basename(path) ?? 'Image',
    SessionMediaOrigin.pasted => 'Pasted image',
    SessionMediaOrigin.captured => shortToolName ?? 'Screenshot',
  };

  /// The tool's name without the MCP routing prefix:
  /// `mcp__karmashala__device_screenshot` is `device_screenshot`.
  String? get shortToolName {
    final name = toolName;
    if (name == null || name.isEmpty) return null;
    final last = name.lastIndexOf('__');
    return last < 0 ? name : name.substring(last + 2);
  }

  static String? _basename(String? path) {
    if (path == null || path.isEmpty) return null;
    final parts = path.split(RegExp(r'[\\/]'));
    final name = parts.isEmpty ? path : parts.last;
    return name.isEmpty ? null : name;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'origin': origin.name,
    'sequence': sequence,
    if (path != null) 'path': path,
    if (fromAgentEnvironment) 'agentPath': true,
    if (toolName != null) 'tool': toolName,
    if (at != null) 'at': at!.toIso8601String(),
    if (bytes != null) 'bytes': bytes,
    if (problem != null) 'problem': problem,
    if (pasteId != null) 'pasteId': pasteId,
  };

  /// Rebuilds an item from the manifest, or null when the record is not one we
  /// wrote — a manifest from an older build, or a file somebody edited.
  static SessionMediaItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final sequence = json['sequence'];
    if (id is! String || sequence is! int) return null;
    final origin = SessionMediaOrigin.values
        .where((value) => value.name == json['origin'])
        .firstOrNull;
    if (origin == null) return null;
    final at = json['at'];
    return SessionMediaItem(
      id: id,
      origin: origin,
      sequence: sequence,
      path: json['path'] is String ? json['path'] as String : null,
      fromAgentEnvironment: json['agentPath'] == true,
      toolName: json['tool'] is String ? json['tool'] as String : null,
      at: at is String ? DateTime.tryParse(at) : null,
      bytes: json['bytes'] is int ? json['bytes'] as int : null,
      problem: json['problem'] is String ? json['problem'] as String : null,
      pasteId: json['pasteId'] is int ? json['pasteId'] as int : null,
    );
  }
}
