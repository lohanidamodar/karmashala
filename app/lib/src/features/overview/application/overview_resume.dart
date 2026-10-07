import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/session_engine_provider.dart';
import '../../sessions/application/session_last_active_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../workspaces/data/workspace_data.dart';

/// A session nothing runs now, as the dashboard's Resume… lists it.
@immutable
class ResumeCandidate {
  const ResumeCandidate({
    required this.id,
    required this.title,
    required this.lastActiveAt,
    this.agentId,
    this.agentName,
    this.modelId,
    this.projectId,
    this.projectName,
    this.archived = false,
  });

  final String id;
  final String title;
  final DateTime lastActiveAt;
  final String? agentId;
  final String? agentName;

  /// The model chosen for it, as the CLI's own id; null follows the default.
  final String? modelId;
  final String? projectId;
  final String? projectName;
  final bool archived;

  @override
  bool operator ==(Object other) =>
      other is ResumeCandidate &&
      other.id == id &&
      other.title == title &&
      other.lastActiveAt == lastActiveAt &&
      other.agentId == agentId &&
      other.modelId == modelId &&
      other.projectId == projectId &&
      other.archived == archived;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    lastActiveAt,
    agentId,
    modelId,
    projectId,
    archived,
  );
}

/// Whether anything runs [sessionId] now, or is bringing it back.
bool _runsNow(Ref ref, String sessionId) {
  final launcher = ref.read(sessionLauncherProvider);
  return launcher.livePaneFor(sessionId) != null ||
      ref.read(sessionEngineProvider).isActive(sessionId) ||
      launcher.heldByHostOnly(sessionId) ||
      ref.read(sessionsStartingProvider).contains(sessionId);
}

/// Every session nothing runs now — stopped or ended, archived ones too —
/// newest first.
final overviewResumeCandidatesProvider =
    Provider.autoDispose<List<ResumeCandidate>>((ref) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.title,
        SessionChangeKind.status,
        SessionChangeKind.placement,
      });
      ref.watch(sessionsStartingProvider);
      final workspace = ref.read(workspaceDataProvider);
      final projects = {
        for (final project in ref.watch(sortedProjectsProvider))
          project.id: project.name,
      };
      final installations = ref.read(agentInstallationsDataProvider);
      final registry = ref.read(agentRegistryProvider);
      final lastActiveOf = ref.read(sessionLastActiveProvider);
      final candidates = <ResumeCandidate>[
        for (final session in ref.read(sessionsDataProvider).getAll())
          if (!_runsNow(ref, session.id))
            _candidateOf(
              session,
              projectId: workspace.repository(session.repositoryId)?.projectId,
              projects: projects,
              agentId: installations
                  .getById(session.agentInstallationId)
                  ?.agentId,
              agentName: registry.displayNameFor,
              lastActiveAt: lastActiveOf(session.id).at ?? session.createdAt,
            ),
      ]..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
      return List.unmodifiable(candidates);
    });

ResumeCandidate _candidateOf(
  Session session, {
  required String? projectId,
  required Map<String, String> projects,
  required String? agentId,
  required String Function(String) agentName,
  required DateTime lastActiveAt,
}) => ResumeCandidate(
  id: session.id,
  title: session.title,
  lastActiveAt: lastActiveAt,
  agentId: agentId,
  agentName: agentId == null ? null : agentName(agentId),
  modelId: session.modelId,
  projectId: projectId,
  projectName: projects[projectId],
  archived: session.isArchived,
);

/// [candidates] as the picker shows them: archived ones only with
/// [includeArchived], narrowed to [projectId] and [agentId] when set, and
/// to those whose title, agent, model or project holds every word of
/// [query].
List<ResumeCandidate> filterResumeCandidates(
  List<ResumeCandidate> candidates, {
  String query = '',
  String? projectId,
  String? agentId,
  bool includeArchived = false,
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  return [
    for (final candidate in candidates)
      if ((includeArchived || !candidate.archived) &&
          (projectId == null || candidate.projectId == projectId) &&
          (agentId == null || candidate.agentId == agentId) &&
          words.every(
            [
              candidate.title,
              ?candidate.agentName,
              ?candidate.modelId,
              ?candidate.projectName,
            ].join(' ').toLowerCase().contains,
          ))
        candidate,
  ];
}

/// **Resuming from the dashboard**, kept where the person is: the session
/// comes back at the server — idle, or with a message as its next turn —
/// with no tab and no focus moved. A test puts a stand-in here.
class OverviewResumer {
  OverviewResumer(this._ref);

  final Ref _ref;

  /// Resumes [sessionId]; what to tell the person, if anything, and whether
  /// it failed.
  Future<ExplorerResult> resume(String sessionId, {String? message}) => _ref
      .read(explorerActionsProvider)
      .resumeInBackground(sessionId, message: message);
}

final overviewResumerProvider = Provider<OverviewResumer>(OverviewResumer.new);
