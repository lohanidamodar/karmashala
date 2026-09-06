import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../environments/application/environment_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../domain/session_launch.dart';
import 'session_providers.dart';

/// How often a live session's transcript file is re-read.
const Duration kChatTranscriptPollInterval = Duration(seconds: 2);

/// The interval actually in effect — the seam a test uses to drive the poll
/// without waiting two seconds a tick.
///
/// The same seam, for the same reason, as `deliveryPollIntervalProvider`,
/// `usageRefreshIntervalProvider` and `scrollbackAutosaveFactoryProvider`.
/// Nothing in the app ever sets it.
final chatTranscriptPollIntervalProvider = Provider<Duration>(
  (ref) => kChatTranscriptPollInterval,
);

/// **Whether a mounted conversation is the surface the user is looking at**,
/// and therefore whether its transcript is worth re-reading at all.
///
/// A conversation that has been asked for stays *mounted* behind the terminal
/// — that is what the `IndexedStack` in `WorkbenchView` is for, and it is what
/// keeps its scroll position across the toggle. What it must not do is stay
/// *working*: [sessionChatTranscriptProvider] is a two-second poll and each
/// tick whose file has moved reads and JSON-decodes that session's **whole**
/// transcript on the UI isolate.
///
/// Measured against the owner's own store: the largest Claude Code transcript
/// there is **43.8 MB over 11 637 lines**, and one tick's `openRead` + `utf8` +
/// `LineSplitter` + `jsonDecode`-per-line takes **888 ms**. On a two-second
/// poll, against a file the agent being typed to is still writing, that is
/// nearly half of every second spent parsing a surface nobody can see — which
/// is what "typing lags" was. `test/app/shell/keystroke_cost_test.dart`
/// measures the terminal and the conversation *together*, which is the case
/// each feature's own cost test could not see.
///
/// One bool for the window rather than one per session, because the question
/// is only ever "is *any* conversation on screen" — the only watchers of a
/// transcript are that conversation and the activity strip inside it, so there
/// is nobody else this can starve.
///
/// It used to read the one global "the terminal is up" flag, which was right
/// while the workbench showed one surface at a time. A workspace group now owns
/// its own face, so several conversations can be up at once and the honest
/// question is [anyChatVisibleProvider]: nothing polls while every group is
/// showing its terminal, which is the property this exists for.
final chatTranscriptPollingProvider = Provider<bool>(
  (ref) => ref.watch(anyChatVisibleProvider),
);

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
      // Both loops below sleep and then read a provider, and a `Ref` disposed
      // under a pending delay throws when read — the same reason
      // `UsageRefreshController` keeps a `_disposed` flag.
      var alive = true;
      ref.onDispose(() => alive = false);
      bool polling() => alive && ref.read(chatTranscriptPollingProvider);
      Duration interval() =>
          alive ? ref.read(chatTranscriptPollIntervalProvider) : Duration.zero;

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
      //
      // Gated by [chatTranscriptPollingProvider] like the read loop below, and
      // for a sharper reason: a session whose file has not appeared yet retries
      // the *whole store walk* every three seconds — 540 files on the owner's
      // machine — and a conversation mounted behind the terminal would run it
      // for a surface nobody can see.
      String? path;
      final locator = ref.read(sessionTranscriptLocatorProvider);
      yield const [];
      while (path == null) {
        if (!alive) return;
        if (!polling()) {
          await Future<void>.delayed(interval());
          continue;
        }
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
        // **Paused while the terminal is the surface in front.** Not stopped:
        // the loop keeps its cadence and its `lastModified`, so the first tick
        // after the user switches back sees the file has moved and re-reads it
        // — the conversation is at most one interval stale when it reappears,
        // which is exactly how stale it already is while visible. Skipping the
        // `stat` as well as the read is deliberate: on a
        // `\\wsl.localhost\...` share a `stat` is ~1.2 ms, and there is no
        // question it can answer for a surface nobody is looking at.
        if (!alive) return;
        if (!polling()) {
          await Future<void>.delayed(interval());
          continue;
        }
        DateTime? modified;
        try {
          // `stat()` rather than `existsSync()` + `lastModifiedSync()`: this
          // runs on the UI isolate, and the transcripts it polls can live on a
          // `\\wsl.localhost\...` share where the synchronous pair measures
          // 1.19 ms against 0.07 ms locally. One file every two seconds is not
          // the hitch Loop 90 was chasing, but there is no reason to block for
          // it — the asynchronous form runs on `dart:io`'s thread pool.
          final stat = await file.stat();
          modified = stat.type == FileSystemEntityType.notFound
              ? null
              : stat.modified;
        } catch (_) {
          modified = null;
        }
        if (first || modified != lastModified) {
          first = false;
          lastModified = modified;
          yield await readCliTranscript(path, agentId);
        }
        await Future<void>.delayed(interval());
      }
    });
