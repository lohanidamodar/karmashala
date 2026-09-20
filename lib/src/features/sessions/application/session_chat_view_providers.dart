import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/launch.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **The screen: everything answerable without touching a disk.** Both refusals
/// it can reach are final; everything else leaves unread, carrying its prior.
SessionChatView screenSessionChatView(Ref ref, String sessionId) {
  const nothingToRead = SessionChatView.read(
    ChatViewEvidence.noSessionRecord,
    prior: false,
  );
  final row = ref.read(sessionDaoProvider).getById(sessionId);
  if (row == null) return nothingToRead;
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(row.agentInstallationId)
      ?.agentId;
  if (agentId == null) return nothingToRead;
  // **The store's answer comes before the session's**: a session with no CLI
  // id yet will get one, and an agent whose store we cannot open will not.
  final descriptor = ref.read(agentRegistryProvider).byId(agentId);
  final format = descriptor?.store?.format;
  if (format == null || format == AgentStoreFormat.none) {
    return const SessionChatView.read(
      ChatViewEvidence.storeUnreadable,
      prior: false,
    );
  }
  final externalId = row.externalSessionId;
  if (externalId == null || externalId.isEmpty) return nothingToRead;
  return SessionChatView.unread(prior: agentSupportsChatView(descriptor));
}

/// **The measurement, once the scan has said where the file would be.** A
/// missing file is a refusal only when it is a *different* file from that one.
Future<SessionChatView> readChatViewAt({
  required String? storePath,
  required String agentId,
  required bool prior,
  required DateTime at,
}) async {
  if (storePath == null) {
    return SessionChatView.read(
      ChatViewEvidence.notLocated,
      prior: prior,
      checkedAt: at,
    );
  }
  final file = transcriptFileFor(storePath, agentId);
  if (file == null) {
    return SessionChatView.read(
      ChatViewEvidence.storeUnreadable,
      prior: prior,
      path: storePath,
      checkedAt: at,
    );
  }
  if (await File(file).exists()) {
    return SessionChatView.read(
      ChatViewEvidence.transcriptOnDisk,
      prior: prior,
      path: file,
      checkedAt: at,
    );
  }
  return SessionChatView.read(
    file == storePath
        ? ChatViewEvidence.notLocated
        : ChatViewEvidence.transcriptAbsent,
    prior: prior,
    path: file,
    checkedAt: at,
  );
}

/// One store scan and one `exists()`, for a session whose refusal has to be
/// earned. Free for everything else, **including a prior of yes**.
final sessionChatViewProbeProvider = FutureProvider.autoDispose
    .family<SessionChatView, String>((ref, sessionId) async {
      final screen = screenSessionChatView(ref, sessionId);
      if (screen.isMeasured || screen.prior) return screen;
      final row = ref.read(sessionDaoProvider).getById(sessionId)!;
      final agentId = ref
          .read(agentInstallationDaoProvider)
          .getById(row.agentInstallationId)!
          .agentId;
      final storePath = await ref
          .read(sessionTranscriptLocatorProvider)
          .locate(agentId: agentId, externalSessionId: row.externalSessionId!);
      return readChatViewAt(
        storePath: storePath,
        agentId: agentId,
        prior: screen.prior,
        at: ref.read(clockProvider).nowUtc(),
      );
    });

/// **Whether this session has a chat view** — one reading shared by every
/// surface. Only a refusal costs a scan; a readable format keeps its prior.
final sessionChatViewProvider = Provider.autoDispose
    .family<SessionChatView, String>((ref, sessionId) {
      // The row's CLI conversation is `placement`, and a row appearing or going
      // away is `membership`; nothing else can change this answer.
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
      });
      final screen = screenSessionChatView(ref, sessionId);
      if (screen.isMeasured || screen.prior) return screen;
      // The prior stands until the probe answers — an unknown is never a zero,
      // and this one says in `reason` that it is a prior about the format.
      return ref.watch(sessionChatViewProbeProvider(sessionId)).asData?.value ??
          screen;
    });
