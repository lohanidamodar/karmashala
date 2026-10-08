import 'package:karmashala_core/visuals.dart';

/// One visual an agent drew in its thread with `visualize`, as it now
/// stands. [id] is the agent's handle for updating it in place; [revision]
/// counts the times it changed.
class SessionVisual {
  const SessionVisual({
    required this.sessionId,
    required this.id,
    required this.kind,
    required this.data,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.title,
  });

  final String sessionId;
  final String id;

  /// The kind's name, kept as text so a newer server's kind still travels.
  final String kind;
  final String? title;

  /// The spec in its stored shape; [spec] reads it.
  final Object? data;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  VisualKind? get visualKind => VisualKind.parse(kind);

  /// [data] read as its kind. Throws a [FormatException] for one this build
  /// cannot draw, which a client shows beside the source.
  VisualSpec get spec {
    final kind = visualKind;
    if (kind == null) {
      throw FormatException(
        '"${this.kind}" visuals are not drawn by this version',
      );
    }
    return parseVisualSpec(kind, data);
  }

  SessionVisual copyWith({
    String? title,
    Object? data,
    int? revision,
    DateTime? updatedAt,
  }) => SessionVisual(
    sessionId: sessionId,
    id: id,
    kind: kind,
    title: title ?? this.title,
    data: data ?? this.data,
    revision: revision ?? this.revision,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

Map<String, Object?> sessionVisualToJson(SessionVisual v) => {
  'sessionId': v.sessionId,
  'id': v.id,
  'kind': v.kind,
  'title': ?v.title,
  'data': v.data,
  'revision': v.revision,
  'createdAt': v.createdAt.toIso8601String(),
  'updatedAt': v.updatedAt.toIso8601String(),
};

/// Throws [FormatException] on a copy out of shape.
SessionVisual sessionVisualFromJson(Map<String, Object?> json) {
  T need<T>(String key) {
    final value = json[key];
    if (value is T) return value;
    throw FormatException('visual: "$key" is missing or not a $T');
  }

  return SessionVisual(
    sessionId: need<String>('sessionId'),
    id: need<String>('id'),
    kind: need<String>('kind'),
    title: json['title'] as String?,
    data: json['data'],
    revision: need<int>('revision'),
    createdAt: DateTime.parse(need<String>('createdAt')),
    updatedAt: DateTime.parse(need<String>('updatedAt')),
  );
}
