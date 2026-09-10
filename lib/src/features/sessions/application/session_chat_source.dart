import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';

/// How often a live session's transcript file is re-read.
const Duration kChatTranscriptPollInterval = Duration(seconds: 2);

/// The interval actually in effect — the seam a test uses to drive the poll
/// without waiting two seconds a tick. Nothing in the app ever sets it.
final chatTranscriptPollIntervalProvider = Provider<Duration>(
  (ref) => kChatTranscriptPollInterval,
);

/// **Whether a mounted conversation is the surface the user is looking at**,
/// and therefore whether its transcript is worth re-reading at all.
///
/// A conversation stays *mounted* behind the terminal — that is what the
/// `IndexedStack` is for, and it keeps the scroll position — but it must not
/// stay *working*: [sessionChatTranscriptProvider] is a two-second poll, and
/// each tick whose file has moved JSON-decodes that session's **whole**
/// transcript on the UI isolate. The largest in the owner's store is 43.8 MB
/// over 11 637 lines and takes 888 ms a tick, which is what "typing lags" was.
///
/// One bool for the window rather than one per session: the only watchers of a
/// transcript are that conversation and the strip inside it, so there is nobody
/// else this can starve. [anyChatVisibleProvider] rather than the old global
/// terminal flag, because a workspace group now owns its own face.
final chatTranscriptPollingProvider = Provider<bool>(
  (ref) => ref.watch(anyChatVisibleProvider),
);

/// How long to keep looking for a transcript the agent has not written yet. A
/// CLI creates its session file when it starts a turn, not when it launches, so
/// the file legitimately does not exist for the first few seconds.
const Duration kChatTranscriptSearchInterval = Duration(seconds: 3);

/// Finds the file an agent is recording a session into — the chat view is built
/// from **the agent's own structured record**, not a second copy.
///
/// Parsing the process's output instead is not an option: Claude Code's
/// `--output-format stream-json` "only works with `--print`", and Codex's
/// structured protocol is the separate `app-server` subcommand, so a PTY
/// session has no second stream to read. That leaves the parser off the
/// critical path — a format that changes degrades the rendering and **the
/// session keeps running**.
///
/// Located by **searching the store for the session's own id** rather than by
/// reconstructing a path: Claude Code's directory name is a lossy dash-encoding
/// of the working directory and Codex files sit under a date tree, and a search
/// asks the readers that already understand both.
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
  /// The bulk form: the scan costs the same whether it answers for one session
  /// or five hundred, so asking once per session paid for the same walk over
  /// and over. An empty map is the same answer as a store we cannot read.
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
/// polled while the session is on screen. Yields an empty list — never an error
/// — for a session whose agent has no readable store, or whose file has not
/// appeared yet; the terminal view is always there either way.
final sessionChatTranscriptProvider = StreamProvider.autoDispose
    .family<List<TranscriptMessage>, String>((ref, sessionId) async* {
      // Both loops below sleep and then read a provider, and a `Ref` disposed
      // under a pending delay throws when read.
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
      // Taken before the first `await`, because `ref` may not be watched after
      // one. Free for a store format the allowlist reads; one scan plus one
      // `exists()` for a session whose refusal has to be earned.
      final reading = ref.watch(sessionChatViewProbeProvider(sessionId).future);
      if (agentId == null) {
        yield const [];
        return;
      }
      if (!(await reading).hasChatView) {
        yield const [];
        return;
      }

      // The store scan is expensive, so it runs only until the file is found
      // and never again. Gated by [chatTranscriptPollingProvider] for a sharper
      // reason than the read loop below: a session whose file has not appeared
      // retries the *whole store walk* every three seconds — 540 files on the
      // owner's machine.
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
        // **Paused while the terminal is the surface in front**, not stopped:
        // the loop keeps its cadence and its `lastModified`, so the first tick
        // after the user switches back sees the file has moved and re-reads it.
        // Skipping the `stat` as well as the read is deliberate — it answers no
        // question for a surface nobody is looking at.
        if (!alive) return;
        if (!polling()) {
          await Future<void>.delayed(interval());
          continue;
        }
        DateTime? modified;
        try {
          // `stat()` rather than `existsSync()` + `lastModifiedSync()`: this
          // runs on the UI isolate, and on a `\\wsl.localhost\...` share the
          // synchronous pair measures 1.19 ms against 0.07 ms locally.
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
