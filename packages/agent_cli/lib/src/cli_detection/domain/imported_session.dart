/// A CLI session (Claude Code / Codex) imported into the workspace as read-only
/// history, attached to one of our repositories.
class ImportedSession {
  const ImportedSession({
    required this.id,
    required this.repositoryId,
    required this.cli,
    required this.externalId,
    required this.environmentId,
    required this.filePath,
    required this.storeHome,
    required this.isSubagent,
    required this.preview,
    required this.createdAt,
    this.title,
    this.updatedAt,
  });

  final String id;
  final String repositoryId;

  /// The `AgentDescriptor.id` of the originating CLI.
  final String cli;

  /// The CLI's own session id (used with [cli] to dedupe re-imports).
  final String externalId;

  final String environmentId;
  final String filePath;
  final String storeHome;
  final bool isSubagent;
  final String? title;
  final String preview;
  final DateTime? updatedAt;
  final DateTime createdAt;

  String get displayTitle {
    final t = title;
    if (t != null && t.trim().isNotEmpty) return t;
    if (preview.trim().isNotEmpty) return preview;
    return '(imported session)';
  }

  @override
  bool operator ==(Object other) =>
      other is ImportedSession &&
      other.id == id &&
      other.repositoryId == repositoryId &&
      other.cli == cli &&
      other.externalId == externalId &&
      other.environmentId == environmentId &&
      other.filePath == filePath &&
      other.storeHome == storeHome &&
      other.isSubagent == isSubagent &&
      other.title == title &&
      other.preview == preview &&
      other.updatedAt == updatedAt &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    repositoryId,
    cli,
    externalId,
    environmentId,
    filePath,
    storeHome,
    isSubagent,
    title,
    preview,
    updatedAt,
    createdAt,
  );

  ImportedSession copyWith({String? title}) => ImportedSession(
    id: id,
    repositoryId: repositoryId,
    cli: cli,
    externalId: externalId,
    environmentId: environmentId,
    filePath: filePath,
    storeHome: storeHome,
    isSubagent: isSubagent,
    preview: preview,
    createdAt: createdAt,
    title: title ?? this.title,
    updatedAt: updatedAt,
  );
}
