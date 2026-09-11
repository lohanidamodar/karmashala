import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/descriptors.dart';
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

/// Whether a mounted conversation is the surface on screen, and so whether its
/// transcript is worth re-reading: one 43.8 MB parse costs 888 ms on the UI.
final chatTranscriptPollingProvider = Provider<bool>(
  (ref) => ref.watch(anyChatVisibleProvider),
);

/// How long to keep looking for a transcript the agent has not written yet: a
/// CLI creates its session file when it starts a turn, not when it launches.
const Duration kChatTranscriptSearchInterval = Duration(seconds: 3);

/// Finds the file an agent records a session into — a PTY session has no second
/// stream to parse, so the store is searched for the session's own id.
class SessionTranscriptLocator {
  const SessionTranscriptLocator(this._ref);

  final Ref _ref;

  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async {
    if (externalSessionId.isEmpty) return null;
    final found = (await index())['$agentId/$externalSessionId'];
    if (found != null || agentId != AgentIds.antigravity) return found;
    return _antigravityRecordFor(externalSessionId);
  }

  /// The scan leaves out an Antigravity conversation its store places in no
  /// directory (`AntigravityStoreSessions`) — 38 of the 44 with a transcript
  /// here. Its record is looked for by id instead, in every store located.
  Future<String?> _antigravityRecordFor(String id) async {
    try {
      for (final store in await _stores()) {
        final home = store.antigravityHome;
        if (home == null) continue;
        for (final extension in const ['.db', '.pb']) {
          final record = p.join(home, 'conversations', '$id$extension');
          if (await File(record).exists()) return record;
        }
      }
    } catch (_) {
      // A store we cannot read is the same answer as one with nothing in it.
    }
    return null;
  }

  Future<List<CliStore>> _stores() => _ref
      .read(cliStoreLocatorProvider)
      .locate(_ref.read(executionEnvironmentDaoProvider).getAll());

  /// Every transcript one scan can find, keyed `'<agentId>/<sessionId>'`. The
  /// scan costs the same for one session or five hundred; empty is unreadable.
  Future<Map<String, String>> index() async {
    final found = <String, String>{};
    try {
      final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
      final stores = await _stores();
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

/// The chat rendering of a PTY-hosted session, polled while it is on screen.
/// An empty list — never an error — for a store or file we cannot read yet.
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
      // one. Free unless this session's refusal has to be earned.
      final reading = ref.watch(sessionChatViewProbeProvider(sessionId).future);
      if (agentId == null) {
        yield const [];
        return;
      }
      if (!(await reading).hasChatView) {
        yield const [];
        return;
      }

      // The store scan runs only until the file is found. Gated on a visible
      // conversation: an unfound file retries the whole walk every 3 seconds.
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
        // Paused, not stopped: the loop keeps its cadence and `lastModified`,
        // so the first tick back sees it moved. The `stat` is skipped too.
        if (!alive) return;
        if (!polling()) {
          await Future<void>.delayed(interval());
          continue;
        }
        DateTime? modified;
        try {
          // `stat()`, not the sync pair: on a `\\wsl.localhost\...` share the
          // pair measures 1.19 ms against 0.07 ms locally, on the UI isolate.
          final stat = await file.stat();
          modified = stat.type == FileSystemEntityType.notFound
              ? null
              : stat.modified;
        } catch (_) {
          modified = null;
        }
        var spent = Duration.zero;
        if (first || modified != lastModified) {
          first = false;
          lastModified = modified;
          final parse = Stopwatch()..start();
          // Off the UI isolate: this parse is seconds on a long conversation.
          yield await readCliTranscriptOffThread(path, agentId);
          spent = parse.elapsed;
        }
        // Rest at least as long as the last read took, so a transcript slower
        // to parse than the interval cannot hold a core for the whole session.
        final rest = interval();
        await Future<void>.delayed(spent > rest ? spent : rest);
      }
    });
