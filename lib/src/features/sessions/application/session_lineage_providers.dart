import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../domain/session.dart';
import '../domain/session_lineage.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';

/// Where a session sits among the sessions it came from and the ones that came
/// from it.
///
/// Exposed for the explorer to render — a sidebar can show that a session was
/// handed off from another, or that three forks hang off one conversation —
/// **without this feature owning any of that drawing**. Nothing here knows what
/// a tree looks like; it answers the question and stops.
///
/// Watches `sessionsRevisionProvider` so a handoff or fork made in this session
/// redraws the lineage of the one it came from, which is the case that would
/// otherwise look broken: the parent's row is untouched by its child's creation.
final sessionLineageProvider = Provider.autoDispose
    .family<SessionLineage?, String>((ref, sessionId) {
      ref.watch(sessionsRevisionProvider);
      final dao = ref.watch(sessionDaoProvider);
      final installations = ref.watch(agentInstallationDaoProvider);

      String? agentOf(Session session) =>
          installations.getById(session.agentInstallationId)?.agentId;

      SessionLineageNode nodeOf(Session session) => SessionLineageNode(
        sessionId: session.id,
        title: session.title,
        link: session.parentLink,
        agentId: agentOf(session),
      );

      return SessionLineage.build(
        sessionId,
        lookup: (id) {
          final session = dao.getById(id);
          if (session == null) return null;
          return (node: nodeOf(session), parentId: session.parentSessionId);
        },
        children: (id) => dao.childrenOf(id).map(nodeOf).toList(),
      );
    });
