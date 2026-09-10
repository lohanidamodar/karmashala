import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../domain/session_chat_view.dart';
import '../domain/session_launch.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **The screen: everything answerable without touching a disk.** Both refusals
/// it can reach are final — a session with no CLI id has nothing to look for,
/// and an agent whose store format nothing here opens has none for *any* of its
/// sessions. Everything else leaves with [ChatViewEvidence.unread] carrying the
/// allowlist as its prior, which is all `agentSupportsChatView` is now used
/// for.
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
  // **The store's answer comes before the session's**, because it is the
  // durable one: a session with no CLI id yet will get one, and an agent whose
  // store nothing here opens will not.
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

/// **The measurement, once the store scan has said where this session's file
/// would be.** [storePath] is what the scan found — for Antigravity the
/// protobuf `conversations/<id>.db` and not the transcript — and
/// [transcriptFileFor] turns it into the file the conversation is actually read
/// from, so this and `readCliTranscript` cannot disagree about which file was
/// meant.
///
/// **A missing file is a refusal only when it is a different file.** Where the
/// transcript *is* the record the scan found (Claude Code, Codex), an
/// `exists()` saying no is a stale scan — [ChatViewEvidence.notLocated]. Where
/// it is derived from the record beside it, its absence is the store's own
/// final answer: it keeps the conversation and keeps no readable record of it.
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
/// earned. Runs when a surface asks and never again. Answers straight out of
/// the screen for everything else, **including a prior of yes**, so awaiting
/// this is free for a Claude Code or Codex session: it touches no disk.
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
          .locate(
            agentId: agentId,
            externalSessionId: row.externalSessionId!,
          );
      return readChatViewAt(
        storePath: storePath,
        agentId: agentId,
        prior: screen.prior,
        at: ref.read(clockProvider).nowUtc(),
      );
    });

/// **Whether this session has a chat view** — one reading, shared by the
/// conversation, the plan panel and the companion snapshot, so no two of them
/// can describe one session differently. `autoDispose`, so a closed panel
/// subscribes to nothing and the probe below never runs.
///
/// Only a **refusal** is paid for: the screen's prior is `false`, so the probe
/// locates the session and looks. A format the allowlist reads is readable for
/// every session of it, and whether *this* one's file exists yet is measured
/// downstream by `sessionChatTranscriptProvider`. So Claude Code and Codex cost
/// no scan and no `stat`, and an Antigravity session costs one scan and one
/// `exists()`, once, when a surface that would show its conversation opens.
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
