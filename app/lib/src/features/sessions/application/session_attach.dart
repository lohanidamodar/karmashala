import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_session/lineage.dart' show SessionDepth;
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../workspaces/data/workspace_data.dart';
import '../data/sessions_client.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Attaches a top-level session under a parent**, at the server: it becomes
/// the parent's sub-session and reports to it when it finishes. A refusal is
/// thrown as a [StateError] in the server's own words.
final sessionAttachProvider =
    Provider<Future<void> Function(String sessionId, String parentId)>((ref) {
      final client = ref.watch(sessionsClientProvider);
      return (sessionId, parentId) =>
          client.attach(sessionId, parentId: parentId);
    });

/// A session Attach to… offers as the parent, and why it cannot be one.
@immutable
class AttachParentCandidate {
  const AttachParentCandidate({
    required this.id,
    required this.title,
    required this.createdAt,
    this.agentName,
    this.projectName,
    this.refusal,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final String? agentName;
  final String? projectName;

  /// Why it cannot be the parent; null when it can.
  final String? refusal;

  bool get allowed => refusal == null;

  @override
  bool operator ==(Object other) =>
      other is AttachParentCandidate &&
      other.id == id &&
      other.title == title &&
      other.createdAt == createdAt &&
      other.agentName == agentName &&
      other.projectName == projectName &&
      other.refusal == refusal;

  @override
  int get hashCode =>
      Object.hash(id, title, createdAt, agentName, projectName, refusal);
}

/// Every session but [childId] and the archived ones as a parent for it,
/// those it can attach to first, newest first. One under it would loop, and
/// one too deep for it and its own sub-sessions is past the cap: both are
/// listed with the reason, not hidden.
List<AttachParentCandidate> attachParentCandidates(
  String childId,
  List<Session> sessions, {
  String? Function(Session session)? agentName,
  String? Function(Session session)? projectName,
}) {
  final byId = {for (final s in sessions) s.id: s};
  final child = byId[childId];
  if (child == null) return const [];
  String? parentOf(String id) => byId[id]?.parentSessionId;
  final below = _height(childId, sessions);

  String? refusalFor(Session parent) {
    if (_isUnder(parent.id, childId, parentOf)) {
      return 'Under "${child.title}": attaching would loop.';
    }
    final depth = SessionDepth.forChildOf(parent.id, parentOf);
    if (!depth.isAllowed || depth.depth + below > SessionDepth.maxDepth) {
      return 'Too deep: sessions nest at most ${SessionDepth.maxDepth} '
          'levels.';
    }
    return null;
  }

  final candidates = [
    for (final parent in sessions)
      if (parent.id != childId && !parent.isArchived)
        AttachParentCandidate(
          id: parent.id,
          title: parent.title,
          createdAt: parent.createdAt,
          agentName: agentName?.call(parent),
          projectName: projectName?.call(parent),
          refusal: refusalFor(parent),
        ),
  ];
  candidates.sort((a, b) {
    if (a.allowed != b.allowed) return a.allowed ? -1 : 1;
    return b.createdAt.compareTo(a.createdAt);
  });
  return candidates;
}

/// [candidates] whose title, agent or project holds every word of [query].
List<AttachParentCandidate> filterAttachParents(
  List<AttachParentCandidate> candidates,
  String query,
) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return candidates;
  return [
    for (final c in candidates)
      if (words.every(
        (word) => [
          c.title,
          ?c.agentName,
          ?c.projectName,
        ].any((field) => field.toLowerCase().contains(word)),
      ))
        c,
  ];
}

/// The parents [attachParentCandidates] offers for [String], named with
/// their agent and project.
final attachParentCandidatesProvider = Provider.autoDispose
    .family<List<AttachParentCandidate>, String>((ref, childId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.title,
        SessionChangeKind.status,
      });
      final workspace = ref.read(workspaceDataProvider);
      final projects = {
        for (final project in ref.watch(sortedProjectsProvider))
          project.id: project.name,
      };
      final installations = ref.read(agentInstallationsDataProvider);
      final registry = ref.read(agentRegistryProvider);
      return List.unmodifiable(
        attachParentCandidates(
          childId,
          ref.read(sessionsDataProvider).getAll(),
          agentName: (session) {
            final agentId = installations
                .getById(session.agentInstallationId)
                ?.agentId;
            return agentId == null ? null : registry.displayNameFor(agentId);
          },
          projectName: (session) =>
              projects[workspace.repository(session.repositoryId)?.projectId],
        ),
      );
    });

/// Whether [ancestorId] is [id] or above it.
bool _isUnder(String id, String ancestorId, String? Function(String) parentOf) {
  final seen = <String>{};
  String? current = id;
  while (current != null && seen.add(current)) {
    if (current == ancestorId) return true;
    current = parentOf(current);
  }
  return false;
}

/// Levels of sub-sessions under [id]; 0 for none.
int _height(String id, List<Session> sessions, [int walked = 0]) {
  if (walked >= SessionDepth.maxWalk) return walked;
  var most = 0;
  for (final s in sessions) {
    if (s.parentSessionId != id) continue;
    final below = 1 + _height(s.id, sessions, walked + 1);
    if (below > most) most = below;
  }
  return most;
}
