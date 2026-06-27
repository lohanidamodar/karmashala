import '../../agents/domain/agent_kind.dart';

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

  /// The originating CLI (`claudeCode` or `codex`).
  final AgentKind cli;

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
