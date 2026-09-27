import 'dart:async';
import 'dart:convert';

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/discovery.dart' hide Clock, IdGenerator;
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/git/application/git_providers.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';

/// Resolves the [AgentChatProtocol] for an `AgentDescriptor.id`. Agents with a
/// protocol adapter get theirs; anything else gets the generic one.
typedef ChatProtocolResolver = AgentChatProtocol Function(String agentId);

/// Runs agent sessions: the normalized, append-only event log and the session
/// status, both written through the server. Protocol-agnostic — it speaks only
/// [AgentChatProtocol]/[AgentSession].
class SessionEngine {
  SessionEngine({
    required this.sessions,
    required this.records,
    required this.worktreeService,
    required this.resolveProtocol,
    required this.clock,
    required this.ids,
  });

  final SessionsData sessions;
  final SessionRecordsData records;
  final WorktreesClient worktreeService;
  final ChatProtocolResolver resolveProtocol;
  final Clock clock;
  final IdGenerator ids;

  final Map<String, _Runtime> _runtimes = {};

  /// Session ids that are currently running.
  Iterable<String> get activeSessionIds => _runtimes.keys;

  bool isActive(String sessionId) => _runtimes.containsKey(sessionId);

  /// A live broadcast of events for an active session, or `null` if not
  /// running.
  Stream<SessionEvent>? watch(String sessionId) =>
      _runtimes[sessionId]?.controller.stream;

  /// Completes when an active session finishes (completed/failed/cancelled).
  Future<void>? whenDone(String sessionId) => _runtimes[sessionId]?.done.future;

  /// Starts a session for [repository] using [installation]. With [useWorktree]
  /// a dedicated Git worktree is created first and the agent runs there.
  Future<Session> start({
    required Repository repository,
    required AgentInstallation installation,
    required String title,
    bool useWorktree = false,
    List<Repository> additionalRepositories = const [],
    required ResolvedPermission permission,
    String? resumeSessionId,
  }) async {
    final id = ids.newId();

    EnvironmentPath workingDirectory = repository.path;
    EnvironmentPath? worktree;
    WorktreeCreated? created;
    if (useWorktree) {
      created = await worktreeService.create(
        repo: repository.path,
        worktreeName: sessionWorktreeName(id),
        branch: sessionBranchName(id),
        launchesAgent: true,
      );
      workingDirectory = created.worktree.path;
      worktree = created.worktree.path;
    }

    final session = Session(
      id: id,
      repositoryId: repository.id,
      agentInstallationId: installation.id,
      title: title,
      useWorktree: useWorktree,
      worktree: worktree,
      status: SessionStatus.running,
      createdAt: clock.nowUtc(),
      externalSessionId: resumeSessionId,
    );
    // Awaited: the log's first event names this row, and the server refuses
    // an event for a session it has not got.
    await sessions.create(
      session,
      repositories: [for (final extra in additionalRepositories) extra.id],
    );

    _attach(
      sessionId: id,
      title: title,
      workingDirectory: workingDirectory,
      installation: installation,
      permission: permission,
      resumeSessionId: resumeSessionId,
    );
    created?.tracker.agentStarted();

    return session;
  }

  /// Relaunches the agent for an existing [session]; a no-op when it is
  /// already active, and it reuses the same session id and event log.
  Future<void> resume({
    required Session session,
    required EnvironmentPath workingDirectory,
    required AgentInstallation installation,
    required ResolvedPermission permission,
    String? resumeSessionId,
  }) async {
    if (_runtimes.containsKey(session.id)) return;
    sessions.updateStatus(session.id, SessionStatus.running);
    _attach(
      sessionId: session.id,
      title: session.title,
      workingDirectory: workingDirectory,
      installation: installation,
      permission: permission,
      resumeSessionId: resumeSessionId,
    );
  }

  /// Creates the runtime and wires the agent's event stream into the log.
  void _attach({
    required String sessionId,
    required String title,
    required EnvironmentPath workingDirectory,
    required AgentInstallation installation,
    required ResolvedPermission permission,
    String? resumeSessionId,
  }) {
    // Spawn before anything is registered: a runtime with no agent would take
    // every later message as sent and deliver none of them.
    final AgentSession agent;
    try {
      agent = resolveProtocol(installation.agentId).start(
        AgentLaunch(
          workingDirectory: workingDirectory,
          installation: installation,
          permission: permission,
          resumeSessionId: resumeSessionId,
        ),
      );
    } on Object {
      sessions.updateStatus(sessionId, SessionStatus.failed);
      rethrow;
    }

    final controller = StreamController<SessionEvent>.broadcast();
    final runtime = _Runtime(controller: controller);
    _runtimes[sessionId] = runtime;

    _emit(runtime, sessionId, SessionEventTypes.sessionStarted, {
      'title': title,
    });
    runtime.agent = agent;
    runtime.subscription = agent.events.listen(
      (event) {
        final externalId = event.data['sessionId'];
        if (externalId is String && externalId.isNotEmpty) {
          if (sessions.getById(sessionId)?.externalSessionId != externalId) {
            sessions.updateExternalSessionId(sessionId, externalId);
          }
        }
        // A CLI that exited non-zero reports it as an event before its stream
        // closes; the close alone would read as completed.
        if (event.type == SessionEventTypes.error &&
            event.data['exitCode'] is int) {
          runtime.finalStatus ??= SessionStatus.failed;
        }
        _emit(runtime, sessionId, event.type, event.data);
      },
      onError: (Object error, StackTrace _) {
        _emit(runtime, sessionId, SessionEventTypes.error, {
          'message': '$error',
        });
        _finish(sessionId, SessionStatus.failed);
      },
      onDone: () => _finish(sessionId, SessionStatus.completed),
    );
  }

  /// Sends a user [message] to an active session and records it.
  Future<void> sendMessage(String sessionId, String message) async {
    final runtime = _runtimes[sessionId];
    if (runtime == null) {
      throw StateError('Session $sessionId is not active.');
    }
    _emit(runtime, sessionId, SessionEventTypes.userMessage, {'text': message});
    await runtime.agent?.send(message);
  }

  /// Stops an active session, marking it cancelled.
  Future<void> stop(String sessionId) async {
    final runtime = _runtimes[sessionId];
    if (runtime == null) return;
    runtime.finalStatus = SessionStatus.cancelled;
    await runtime.agent?.stop();
  }

  /// Appends one event through the server, in the order emitted, and hands
  /// it — numbered — to the run's watchers once stored. A write that fails is
  /// logged by nothing but the watcher's silence: the log is best-effort, the
  /// run is not.
  void _emit(
    _Runtime runtime,
    String sessionId,
    String type,
    Map<String, Object?> data,
  ) {
    // The one field that ever carries a tool's output, bounded at the row: a
    // stored row that kept more could restore what the phone got trimmed.
    final text = data['text'];
    final payload = text is String
        ? {...data, 'text': boundedText(text).$1}
        : data;
    final appended = records.append(
      SessionEvent(
        sessionId: sessionId,
        seq: 0, // assigned by the server
        type: type,
        payload: jsonEncode(payload),
        createdAt: clock.nowUtc(),
      ),
    );
    runtime.tail = runtime.tail.then((_) async {
      try {
        final stored = await appended;
        if (!runtime.controller.isClosed) runtime.controller.add(stored);
      } on Object {
        // Not stored: nothing to show a watcher.
      }
    });
  }

  void _finish(String sessionId, SessionStatus defaultStatus) {
    final runtime = _runtimes.remove(sessionId);
    if (runtime == null) return;
    final status = runtime.finalStatus ?? defaultStatus;
    sessions.updateStatus(sessionId, status);
    _emit(runtime, sessionId, _lifecycleType(status), const {});
    unawaited(runtime.subscription?.cancel());
    // After the events already sent are stored and handed on.
    unawaited(
      runtime.tail.then((_) {
        if (!runtime.controller.isClosed) runtime.controller.close();
        if (!runtime.done.isCompleted) runtime.done.complete();
      }),
    );
  }

  /// Ends every active run and releases what it holds; nothing else does. It
  /// writes no status: a run that was `running` stays so, which a resume needs.
  Future<void> dispose() => _disposal ??= _stopAll();

  Future<void>? _disposal;

  Future<void> _stopAll() async {
    final runtimes = _runtimes.values.toList();
    _runtimes.clear();
    final stopping = <Future<void>>[];
    for (final runtime in runtimes) {
      // Cancelled before the agent is stopped: stopping closes its stream, and
      // the `onDone` that would fire is the status write we are avoiding.
      unawaited(runtime.subscription?.cancel());
      runtime.subscription = null;
      final agent = runtime.agent;
      if (agent != null) {
        stopping.add(agent.stop().catchError((Object _) {}));
      }
      if (!runtime.controller.isClosed) unawaited(runtime.controller.close());
      if (!runtime.done.isCompleted) runtime.done.complete();
    }
    await Future.wait(stopping);
  }

  String _lifecycleType(SessionStatus status) => switch (status) {
    SessionStatus.completed => SessionEventTypes.sessionCompleted,
    SessionStatus.failed => SessionEventTypes.sessionFailed,
    SessionStatus.cancelled => SessionEventTypes.sessionCancelled,
    _ => SessionEventTypes.agentStatus,
  };
}

class _Runtime {
  _Runtime({required this.controller});

  final StreamController<SessionEvent> controller;
  final Completer<void> done = Completer<void>();

  /// The events sent and not yet handed to watchers, in order.
  Future<void> tail = Future.value();
  AgentSession? agent;
  StreamSubscription<AgentEvent>? subscription;
  SessionStatus? finalStatus;
}
