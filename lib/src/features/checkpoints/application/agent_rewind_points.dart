import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';

/// What the agent's own undo offers for [sessionId]'s agent — asked of its
/// adapter, so an agent nobody has read the undo of says nothing.
final sessionAgentRewindProvider = Provider.autoDispose
    .family<AgentRewind, String>((ref, sessionId) {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return const AgentRewind.unknown();
      final agentId = ref
          .read(agentInstallationDaoProvider)
          .getById(session.agentInstallationId)
          ?.agentId;
      if (agentId == null) return const AgentRewind.unknown();
      return ref.read(agentRegistryProvider).adapterFor(agentId)?.rewind ??
          const AgentRewind.unknown();
    });

/// The agent's own rewind points for [sessionId], or `null` when its agent
/// keeps none this app can read. Read once per open panel: it scans the store.
final agentRewindPointsProvider = FutureProvider.autoDispose
    .family<AgentRewindPoints?, String>((ref, sessionId) async {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      final externalId = session?.externalSessionId;
      if (session == null || externalId == null || externalId.isEmpty) {
        return null;
      }
      final agentId = ref
          .read(agentInstallationDaoProvider)
          .getById(session.agentInstallationId)
          ?.agentId;
      if (agentId == null) return null;
      final rewind = ref
          .read(agentRegistryProvider)
          .adapterFor(agentId)
          ?.rewind;
      if (rewind is! OwnRewindPoints) return null;
      final path = await ref
          .read(sessionTranscriptLocatorProvider)
          .locate(agentId: agentId, externalSessionId: externalId);
      if (path == null) return null;
      try {
        final lines = await File(path)
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.contains(rewind.lineMarker))
            .toList();
        return rewind.parse(lines);
      } on FileSystemException {
        return null;
      }
    });
