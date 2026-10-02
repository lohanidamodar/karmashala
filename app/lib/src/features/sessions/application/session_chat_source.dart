import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefusalCode, DataRefused;
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../data/server_transcripts.dart';
import 'acp_session_providers.dart';
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
/// A phone in the background is not showing it; a desktop window that lost
/// focus still is.
final chatTranscriptPollingProvider = Provider<bool>(
  (ref) =>
      ref.watch(anyChatVisibleProvider) &&
      (ref.watch(capabilitiesProvider.select((c) => c.systemIntegration)) ||
          ref.watch(windowFocusedProvider)),
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
    if (found != null) return found;
    final store = _ref.read(agentRegistryProvider).adapterFor(agentId)?.store;
    if (store == null) return null;
    return _recordFor(agentId, store, externalSessionId);
  }

  /// A store's scan can leave out a conversation it files under no directory
  /// (38 of the 44 Antigravity conversations with a transcript, measured). Its
  /// record is looked for by id instead, where the adapter says it may be, in
  /// every store located.
  Future<String?> _recordFor(
    String agentId,
    AgentStore store,
    String id,
  ) async {
    try {
      for (final located in await _stores()) {
        final home = located.homeFor(agentId);
        if (home == null) continue;
        for (final record in store.recordCandidates(home, id)) {
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
      .locate(_ref.read(environmentsDataProvider).getAll());

  /// Every transcript one scan can find, keyed `'<agentId>/<sessionId>'`. The
  /// scan costs the same for one session or five hundred; empty is unreadable.
  Future<Map<String, String>> index() async {
    final found = <String, String>{};
    try {
      final environments = _ref.read(environmentsDataProvider).getAll();
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

/// Session [sessionId]'s transcript as the server reads it
/// (`capabilities.chatViaServer`). Watched while [visible] says so — the
/// chat's own gate, [chatTranscriptPollingProvider] — or always without one.
Stream<List<TranscriptMessage>> serverTranscriptMessages(
  Ref ref,
  String sessionId, {
  Provider<bool>? visible,
}) {
  final lease = ref.read(serverTranscriptsProvider).open(sessionId);
  ref.onDispose(lease.close);
  if (visible == null) {
    lease.watching = true;
  } else {
    lease.watching = ref.read(visible);
    ref.listen<bool>(visible, (_, shown) => lease.watching = shown);
  }
  return lease.windows.map((window) => window.messages);
}

/// Session [sessionId]'s turns as the server reads them, text only, paged
/// back until [enough] (see [ServerTranscripts.turns]). Null when this client
/// reads its own disk instead: a server that does not offer
/// `sessions.transcript.turns`, or refuses it `invalid`.
Future<ServerTurns?> serverSessionTurns(
  Ref ref,
  String sessionId, {
  bool spoken = false,
  required bool Function(List<TranscriptMessage> held) enough,
  void Function(int held, int total)? progress,
}) async {
  if (!ref.read(capabilitiesProvider).turnsViaServer) return null;
  try {
    return await ref
        .read(serverTranscriptsProvider)
        .turns(sessionId, spoken: spoken, enough: enough, progress: progress);
  } on DataRefused catch (refusal) {
    if (refusal.code == DataRefusalCode.invalid) return null;
    rethrow;
  }
}

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

      // The server reads the record where the agent wrote it; this client's
      // disk is read only for a server too old to (Stage 0 step 6).
      final viaServer = ref.watch(
        capabilitiesProvider.select((caps) => caps.chatViaServer),
      );
      final session = ref.read(sessionsDataProvider).getById(sessionId);
      if (session == null) {
        yield const [];
        return;
      }
      // An ACP session's conversation is the server's own rows (ACP design,
      // C3): no file on any disk, and no CLI id to wait for. A server that
      // cannot serve them has nothing to show.
      if (ref.watch(isAcpSessionProvider(sessionId))) {
        if (viaServer) {
          // Watched for as long as it is on screen, not only while a
          // terminal's chat face is up: this session has no terminal, so no
          // face ever flips, and that gate left it loading forever. The
          // server pushes the rows as they are written, so the watch costs
          // nothing between turns.
          yield* serverTranscriptMessages(ref, sessionId);
        } else {
          yield const [];
        }
        return;
      }
      final externalId = session.externalSessionId;
      if (externalId == null || externalId.isEmpty) {
        yield const [];
        return;
      }
      if (viaServer) {
        yield* serverTranscriptMessages(
          ref,
          sessionId,
          visible: chatTranscriptPollingProvider,
        );
        return;
      }
      final agentId = ref
          .read(agentInstallationsDataProvider)
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
      // Parses only what was appended since the last read; a file that did
      // anything but grow is read whole again, off this isolate.
      final tail = CliTranscriptTail(path, agentId);
      DateTime? lastModified;
      int? lastSize;
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
        int? size;
        try {
          // `stat()`, not the sync pair: on a `\\wsl.localhost\...` share the
          // pair measures 1.19 ms against 0.07 ms locally, on the UI isolate.
          final stat = await file.stat();
          final missing = stat.type == FileSystemEntityType.notFound;
          modified = missing ? null : stat.modified;
          size = missing ? null : stat.size;
        } catch (_) {
          modified = null;
          size = null;
        }
        var spent = Duration.zero;
        // Size as well as mtime: mtime is not distinct per write, so an append
        // landing in the tick already read is invisible to the clock alone,
        // and an append-only transcript always moves its size.
        if (first || modified != lastModified || size != lastSize) {
          first = false;
          lastModified = modified;
          lastSize = size;
          final parse = Stopwatch()..start();
          yield await tail.read();
          spent = parse.elapsed;
        }
        // Rest at least as long as the last read took, so a transcript slower
        // to parse than the interval cannot hold a core for the whole session.
        final rest = interval();
        await Future<void>.delayed(spent > rest ? spent : rest);
      }
    });

/// How many turns a session's whole record holds, given the [rows]
/// [sessionChatTranscriptProvider] handed over: through the server, the
/// held window's total — it sends only the tail — else the rows themselves.
/// Null while the transcript is still loading.
final sessionTranscriptTurnsOfProvider =
    Provider<int? Function(String sessionId, List<TranscriptMessage>? rows)>((
      ref,
    ) {
      final transcripts = ref.watch(serverTranscriptsProvider);
      return (sessionId, rows) {
        final window = ref.read(capabilitiesProvider).chatViaServer
            ? transcripts.windowFor(sessionId, rows)
            : null;
        return window?.total ?? rows?.length;
      };
    });
