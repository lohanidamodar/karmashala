import 'package:agent_cli/process.dart';

/// What an artifact is, which decides how a client draws it.
enum ArtifactKind {
  html,
  svg,
  mermaid,
  markdown,
  image,
  pdf;

  static ArtifactKind? parse(String? value) =>
      values.where((k) => k.name == value).firstOrNull;

  /// Whether an agent may hand it as text rather than a file.
  bool get isText => switch (this) {
    html || svg || mermaid || markdown => true,
    image || pdf => false,
  };

  /// The extension a snapshot of inline content is stored under.
  String get extension => switch (this) {
    html => 'html',
    svg => 'svg',
    mermaid => 'mmd',
    markdown => 'md',
    image => 'png',
    pdf => 'pdf',
  };
}

/// How much of the thread it asks for: a card's width, or the full width.
enum ArtifactMode {
  inline,
  wide;

  static ArtifactMode? parse(String? value) =>
      values.where((m) => m.name == value).firstOrNull;
}

/// How the agent made it: the `artifact_show` tool, or a marker in its text.
enum ArtifactOrigin {
  tool,
  marker;

  static ArtifactOrigin? parse(String? value) =>
      values.where((o) => o.name == value).firstOrNull;
}

/// The last look at the source file. The newest snapshot is still shown
/// whichever it is; this says why it may be stale.
enum ArtifactSourceState {
  present,
  missing,
  unreachable,
  tooLarge;

  static ArtifactSourceState? parse(String? value) =>
      values.where((s) => s.name == value).firstOrNull;
}

/// One thing an agent showed in a session's thread. [revision] counts the
/// distinct contents it has had; each is kept as a snapshot on the server.
class Artifact {
  const Artifact({
    required this.id,
    required this.sessionId,
    required this.title,
    required this.kind,
    required this.mode,
    required this.origin,
    required this.fileName,
    required this.revision,
    required this.size,
    required this.mimeType,
    required this.createdAt,
    required this.updatedAt,
    this.source,
    bool? hasSource,
    this.networkAllowed = false,
    this.sourceState = ArtifactSourceState.present,
    this.sourceProblem,
  }) : hasSource = hasSource ?? source != null;

  final String id;
  final String sessionId;
  final String title;
  final ArtifactKind kind;
  final ArtifactMode mode;
  final ArtifactOrigin origin;

  /// The file on the session's host it is read from: the server's alone, null
  /// in a client's copy and for content handed inline.
  final EnvironmentPath? source;

  /// Whether it is watched on a host — true in a client's copy too.
  final bool hasSource;
  final String fileName;
  final int revision;

  /// The newest revision's bytes.
  final int size;
  final String mimeType;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Whether an HTML artifact may reach the network. Off until a person
  /// allows it for this one artifact.
  final bool networkAllowed;
  final ArtifactSourceState sourceState;
  final String? sourceProblem;

  Artifact copyWith({
    String? title,
    ArtifactMode? mode,
    int? revision,
    int? size,
    DateTime? updatedAt,
    bool? networkAllowed,
    ArtifactSourceState? sourceState,
    String? Function()? sourceProblem,
  }) => Artifact(
    id: id,
    sessionId: sessionId,
    title: title ?? this.title,
    kind: kind,
    mode: mode ?? this.mode,
    origin: origin,
    source: source,
    hasSource: hasSource,
    fileName: fileName,
    revision: revision ?? this.revision,
    size: size ?? this.size,
    mimeType: mimeType,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    networkAllowed: networkAllowed ?? this.networkAllowed,
    sourceState: sourceState ?? this.sourceState,
    sourceProblem: sourceProblem == null ? this.sourceProblem : sourceProblem(),
  );
}

/// One kept content of an artifact. [path] is the server's snapshot.
class ArtifactRevision {
  const ArtifactRevision({
    required this.artifactId,
    required this.revision,
    required this.size,
    required this.digest,
    required this.path,
    required this.capturedAt,
  });

  final String artifactId;
  final int revision;
  final int size;
  final String digest;
  final String path;
  final DateTime capturedAt;
}

/// The kind a file name says, or null when it says none.
ArtifactKind? artifactKindForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (name.substring(dot + 1).toLowerCase()) {
    'html' || 'htm' => ArtifactKind.html,
    'svg' => ArtifactKind.svg,
    'mmd' || 'mermaid' => ArtifactKind.mermaid,
    'md' || 'markdown' => ArtifactKind.markdown,
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => ArtifactKind.image,
    'pdf' => ArtifactKind.pdf,
    _ => null,
  };
}

/// The media type a client is told, from the kind and the file name.
String artifactMimeType(ArtifactKind kind, String fileName) => switch (kind) {
  ArtifactKind.html => 'text/html',
  ArtifactKind.svg => 'image/svg+xml',
  ArtifactKind.mermaid => 'text/plain',
  ArtifactKind.markdown => 'text/markdown',
  ArtifactKind.pdf => 'application/pdf',
  ArtifactKind.image => switch (fileName.split('.').last.toLowerCase()) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => 'image/png',
  },
};

/// A client's copy: everything but where the source lives on the host.
Map<String, Object?> artifactToClientJson(Artifact artifact) => {
  'id': artifact.id,
  'sessionId': artifact.sessionId,
  'title': artifact.title,
  'kind': artifact.kind.name,
  'mode': artifact.mode.name,
  'origin': artifact.origin.name,
  'hasSource': artifact.hasSource,
  'fileName': artifact.fileName,
  'revision': artifact.revision,
  'size': artifact.size,
  'mimeType': artifact.mimeType,
  'createdAt': artifact.createdAt.toIso8601String(),
  'updatedAt': artifact.updatedAt.toIso8601String(),
  'networkAllowed': artifact.networkAllowed,
  'sourceState': artifact.sourceState.name,
  'sourceProblem': ?artifact.sourceProblem,
};

/// Throws [FormatException] on a copy out of shape — a server of another
/// build — rather than guessing a kind a client would draw wrongly.
Artifact artifactFromJson(Map<String, Object?> json) {
  T need<T>(String key) {
    final value = json[key];
    if (value is T) return value;
    throw FormatException('artifact: "$key" is missing or not a $T');
  }

  T parsed<T>(String key, T? Function(String?) parse) =>
      parse(json[key] as String?) ??
      (throw FormatException('artifact: unknown $key "${json[key]}"'));

  return Artifact(
    id: need<String>('id'),
    sessionId: need<String>('sessionId'),
    title: need<String>('title'),
    kind: parsed('kind', ArtifactKind.parse),
    mode: parsed('mode', ArtifactMode.parse),
    origin: parsed('origin', ArtifactOrigin.parse),
    hasSource: json['hasSource'] == true,
    fileName: need<String>('fileName'),
    revision: need<int>('revision'),
    size: need<int>('size'),
    mimeType: need<String>('mimeType'),
    createdAt: DateTime.parse(need<String>('createdAt')),
    updatedAt: DateTime.parse(need<String>('updatedAt')),
    networkAllowed: json['networkAllowed'] == true,
    sourceState:
        ArtifactSourceState.parse(json['sourceState'] as String?) ??
        ArtifactSourceState.present,
    sourceProblem: json['sourceProblem'] as String?,
  );
}

/// A kept revision as a client sees it: which, how big, when.
class ArtifactRevisionSummary {
  const ArtifactRevisionSummary({
    required this.revision,
    required this.size,
    required this.capturedAt,
  });

  ArtifactRevisionSummary.of(ArtifactRevision r)
    : revision = r.revision,
      size = r.size,
      capturedAt = r.capturedAt;

  final int revision;
  final int size;
  final DateTime capturedAt;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'size': size,
    'capturedAt': capturedAt.toIso8601String(),
  };

  static ArtifactRevisionSummary fromJson(Map<String, Object?> json) =>
      ArtifactRevisionSummary(
        revision: json['revision']! as int,
        size: json['size']! as int,
        capturedAt: DateTime.parse(json['capturedAt']! as String),
      );
}
