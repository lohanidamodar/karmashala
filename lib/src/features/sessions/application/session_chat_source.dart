import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../environments/application/environment_providers.dart';
import '../domain/session_launch.dart';
import 'session_providers.dart';

/// How often a live session's transcript file is re-read.
const Duration kChatTranscriptPollInterval = Duration(seconds: 2);

/// How long to keep looking for a transcript the agent has not written yet.
///
/// A CLI creates its session file when it starts a turn, not when it launches,
/// so the file legitimately does not exist for the first few seconds — and for
/// as long as the user has not said anything.
const Duration kChatTranscriptSearchInterval = Duration(seconds: 3);

/// Finds the file an agent is recording a session into.
///
/// The chat view is built from **the agent's own structured record**, not from a
/// second copy of the conversation, and this is what locates it.
///
/// ## Why not parse the process's output instead
///
/// Because the two are mutually exclusive. Claude Code's `--output-format
/// stream-json` "only works with `--print`", which is its non-interactive mode;
/// Codex's structured protocol is the separate `app-server` subcommand. An agent
/// running in a PTY is showing a human a TUI, and there is no second stream on
/// stdout to read. The structured record for that same conversation exists only
/// on disk.
///
/// That turns out to be the property the design wanted anyway: the chat view is
/// downstream of a file the agent writes for its own reasons, so if its format
/// changes the rendering degrades and **the session keeps running** in the
/// terminal view. The parser is never load-bearing for whether the session is
/// alive.
///
/// Located by **searching the store for the session's own id** rather than by
/// reconstructing a path. Claude Code's directory name is a lossy dash-encoding
/// of the working directory and Codex files are named
/// `rollout-<timestamp>-<id>.jsonl` under a date tree; a search asks the readers
/// that already understand both instead of duplicating either rule.
class SessionTranscriptLocator {
  const SessionTranscriptLocator(this._ref);

  final Ref _ref;

  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async {
    if (externalSessionId.isEmpty) return null;
    return (await index())['$agentId/$externalSessionId'];
  }

  /// Every transcript one scan can find, as `'<agentId>/<sessionId>' → path`.
  ///
  /// The bulk form, and the one the status registry uses. The scan costs the
  /// same whether it answers for one session or five hundred, so asking it once
  /// per session — which is what a per-card poller did — was paying for the
  /// same walk over and over. An empty map is the same answer as a store we
  /// cannot read.
  Future<Map<String, String>> index() async {
    final found = <String, String>{};
    try {
      final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
      final stores = await _ref
          .read(cliStoreLocatorProvider)
          .locate(environments);
      final projects = await _ref.read(cliDetectionServiceProvider).detect(
        stores,
        {for (final environment in environments) environment.id: environment},
      );
      for (final project in projects) {
        for (final session in [
          ...project.sessions,
          ...project.subagentSessions,
        ]) {
          found['${session.cli}/${session.sessionId}'] = session.filePath;
        }
      }
    } catch (_) {
      // A store we cannot read is the same answer as one with nothing in it.
    }
    return found;
  }
}

final sessionTranscriptLocatorProvider = Provider<SessionTranscriptLocator>(
  (ref) => SessionTranscriptLocator(ref),
);

/// The chat rendering of a PTY-hosted session: the agent's own transcript,
/// polled while the session is on screen.
///
/// Yields an empty list — never an error — for a session whose agent has no
/// readable store, or whose file has not appeared yet. "No chat for this agent"
/// is a capability answer (see [agentSupportsChatView]); the terminal view is
/// always there.
final sessionChatTranscriptProvider = StreamProvider.autoDispose
    .family<List<TranscriptMessage>, String>((ref, sessionId) async* {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      final externalId = session?.externalSessionId;
      if (session == null || externalId == null || externalId.isEmpty) {
        yield const [];
        return;
      }
      final agentId = ref
          .read(agentInstallationDaoProvider)
          .getById(session.agentInstallationId)
          ?.agentId;
      final descriptor = agentId == null
          ? null
          : ref.read(agentRegistryProvider).byId(agentId);
      if (agentId == null || !agentSupportsChatView(descriptor)) {
        yield const [];
        return;
      }

      // The store scan is expensive, so it runs only until the file is found and
      // never again: from then on this polls one file's timestamp.
      String? path;
      final locator = ref.read(sessionTranscriptLocatorProvider);
      yield const [];
      while (path == null) {
        path = await locator.locate(
          agentId: agentId,
          externalSessionId: externalId,
        );
        if (path == null) {
          await Future<void>.delayed(kChatTranscriptSearchInterval);
        }
      }

      final file = File(path);
      DateTime? lastModified;
      var first = true;
      while (true) {
        DateTime? modified;
        try {
          modified = file.existsSync() ? file.lastModifiedSync() : null;
        } catch (_) {
          modified = null;
        }
        if (first || modified != lastModified) {
          first = false;
          lastModified = modified;
          yield await readCliTranscript(path, agentId);
        }
        await Future<void>.delayed(kChatTranscriptPollInterval);
      }
    });
