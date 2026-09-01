/// One picture a session produced or was shown.
///
/// The request this exists for, in the owner's words: *"where can i see this
/// image preview in the terminal? i can't see it, may be we can create a media
/// sidebar that shows all the media from current session in descending
/// order?"*
///
/// The transcript already draws a picture for one of the three ways a session
/// acquires one — a tool call whose input names an image file
/// (`TranscriptImagePreview`). The owner had hit the other two, which carry
/// bytes and **no path at all**, so there was nothing on disk for that widget
/// to point at and it drew nothing. A [SessionMediaItem] is the shape all three
/// arrive in once the scan has resolved them: something with a name, a time,
/// and either a file to draw or an honest reason there is none.
library;

/// How a picture got into the conversation. Not decoration: it is what the
/// panel says instead of a path when there is no path, and it decides whether
/// [SessionMediaItem.path] needs translating out of the agent's environment.
enum SessionMediaOrigin {
  /// A tool call read an image file. The path is real, written in the *agent's*
  /// environment, and the file is nearly always still there.
  read('Read'),

  /// A human put a picture into the conversation. The owner's case: pasting
  /// into the terminal records
  /// `{"type":"image","source":{"type":"base64",…}}` and no path anywhere.
  pasted('Pasted'),

  /// A tool answered with a picture — `device_screenshot`,
  /// `browser_screenshot`, `browser_capture`. Only the first of those also
  /// leaves a copy in the temp directory, so the block in the record is the one
  /// source that covers all three.
  captured('Captured');

  const SessionMediaOrigin(this.label);

  /// What the panel calls this kind of item.
  final String label;
}

/// The extensions the scan will write out and the preview will open. The same
/// set `looksLikeImagePath` accepts, because an extracted file that widget
/// refuses is a file nobody can see.
const Map<String, String> kMediaTypeExtensions = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/bmp': 'bmp',
};

/// The biggest single picture the panel will move to disk and hand a decoder.
///
/// Mirrors `kMaxImagePreviewBytes` in the transcript's preview, deliberately:
/// a file the preview would refuse to draw is not worth extracting, and a
/// decode allocates roughly `width * height * 4` bytes whatever the file
/// weighs. Kept here rather than imported so `data/` does not depend on a
/// widget.
const int kMaxSessionMediaBytes = 12 * 1024 * 1024;

/// How many pictures the panel keeps. A long session is unbounded and the
/// extracted copies are real files on disk, so something has to say when to
/// stop; the newest are the ones anybody scrolls to.
const int kSessionMediaCap = 60;

/// One item in the media panel.
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
  });

  /// Stable for the life of the transcript: it is derived from where in the
  /// file the picture was recorded, and a transcript is appended to, never
  /// rewritten in the middle. That is also what lets an extracted copy be found
  /// again without decoding anything.
  final String id;

  final SessionMediaOrigin origin;

  /// Where in the transcript this was recorded — higher is newer. The panel
  /// sorts on this rather than on [at], because a transcript line without a
  /// timestamp is common and an item with no time must still land in the right
  /// place.
  final int sequence;

  /// The file to draw, or null when there is nothing drawable — see [problem].
  final String? path;

  /// Whether [path] was written by the agent and therefore needs translating
  /// into a path this process can open (`/mnt/c/…` → `C:\…`). False for the
  /// copies the scan writes itself: those are already host paths, and putting
  /// one through a WSL translator would corrupt a path that is already right.
  final bool fromAgentEnvironment;

  /// The tool that produced or read it, when one did.
  final String? toolName;

  /// When the transcript says it happened, when the transcript says.
  final DateTime? at;

  /// The size of the picture, when it is known without decoding it.
  final int? bytes;

  /// Why there is no [path]. Set instead of dropping the item: a picture the
  /// panel cannot show is still a picture the session had, and saying so beats
  /// a list that silently omits things.
  final String? problem;

  /// The name to show. The file name where there is one, and what the item
  /// *is* where there is not — a paste has no name and inventing one would be
  /// worse than saying "Pasted image".
  String get label => switch (origin) {
    SessionMediaOrigin.read => _basename(path) ?? 'Image',
    SessionMediaOrigin.pasted => 'Pasted image',
    SessionMediaOrigin.captured => shortToolName ?? 'Screenshot',
  };

  /// The tool's name without the MCP routing prefix nobody reads:
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
    );
  }
}
