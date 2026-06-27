import 'dart:async';
import 'dart:convert';

import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../agents/domain/agent_adapter.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/worktree_service.dart';
import '../../repositories/domain/repository.dart';
import '../../settings/domain/permission_mode.dart';
import '../data/session_dao.dart';
import '../data/session_event_dao.dart';
import '../data/session_repository_dao.dart';
import '../domain/session.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import '../domain/session_status.dart';

/// Resolves the [AgentAdapter] for an agent kind. Loop 6 returns a fake for every
/// kind; real adapters are registered in later loops.
typedef AdapterResolver = AgentAdapter Function(AgentKind kind);

/// Runs agent sessions: persists the normalized, append-only event log, manages
/// session status, and supports multiple concurrent sessions.
///
/// The engine is protocol-agnostic — it talks to [AgentAdapter]/[AgentSession]
/// and serializes their normalized [AgentEvent]s into [SessionEvent] rows. It is
/// the single place that drives a session's lifecycle.
class SessionEngine {
  SessionEngine({
    required this.sessionDao,
    required this.eventDao,
    required this.sessionRepositoryDao,
    required this.worktreeService,
    required this.resolveAdapter,
    required this.clock,
    required this.ids,
  });

  final SessionDao sessionDao;
  final SessionEventDao eventDao;
  final SessionRepositoryDao sessionRepositoryDao;
  final WorktreeService worktreeService;
  final AdapterResolver resolveAdapter;
  final Clock clock;
  final IdGenerator ids;

  final Map<String, _Runtime> _runtimes = {};

  /// Session ids that are currently running.
  Iterable<String> get activeSessionIds => _runtimes.keys;

  bool isActive(String sessionId) => _runtimes.containsKey(sessionId);

  /// A live broadcast of events for an active session, or `null` if not running.
  Stream<SessionEvent>? watch(String sessionId) =>
      _runtimes[sessionId]?.controller.stream;

  /// Completes when an active session finishes (completed/failed/cancelled).
  Future<void>? whenDone(String sessionId) => _runtimes[sessionId]?.done.future;

  /// Starts a session for [repository] using [installation].
  ///
  /// When [useWorktree] is set, a dedicated Git worktree is created first and the
  /// agent runs there; otherwise it runs in the repository itself.
  Future<Session> start({
    required Repository repository,
    required AgentInstallation installation,
    required String title,
    bool useWorktree = false,
    List<Repository> additionalRepositories = const [],
    PermissionMode permissionMode = PermissionMode.ask,
    String? resumeSessionId,
  }) async {
    final id = ids.newId();

    EnvironmentPath workingDirectory = repository.path;
    EnvironmentPath? worktree;
    if (useWorktree) {
      final created = await worktreeService.createForSession(
        repo: repository.path,
        worktreeName: id.substring(0, 8),
        branch: 'session/${id.substring(0, 8)}',
      );
      workingDirectory = created.path;
      worktree = created.path;
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
    );
    sessionDao.insert(session);
    sessionRepositoryDao.link(
      id,
      repository.id,
      role: SessionRepositoryRole.primary,
    );
    for (final extra in additionalRepositories) {
      sessionRepositoryDao.link(id, extra.id);
    }

    _attach(
      sessionId: id,
      title: title,
      workingDirectory: workingDirectory,
      installation: installation,
      permissionMode: permissionMode,
      resumeSessionId: resumeSessionId,
    );

    return session;
  }

  /// Relaunches the agent for an existing [session] (e.g. one that has ended), so
  /// the user can continue it. No-op if it is already active. Reuses the same
  /// session id and event log.
  Future<void> resume({
    required Session session,
    required EnvironmentPath workingDirectory,
    required AgentInstallation installation,
    PermissionMode permissionMode = PermissionMode.ask,
    String? resumeSessionId,
  }) async {
    if (_runtimes.containsKey(session.id)) return;
    sessionDao.updateStatus(session.id, SessionStatus.running);
    _attach(
      sessionId: session.id,
      title: session.title,
      workingDirectory: workingDirectory,
      installation: installation,
      permissionMode: permissionMode,
      resumeSessionId: resumeSessionId,
    );
  }

  /// Creates the runtime and wires the agent's event stream into the log.
  void _attach({
    required String sessionId,
    required String title,
    required EnvironmentPath workingDirectory,
    required AgentInstallation installation,
    required PermissionMode permissionMode,
    String? resumeSessionId,
  }) {
    final controller = StreamController<SessionEvent>.broadcast();
    final runtime = _Runtime(controller: controller);
    _runtimes[sessionId] = runtime;

    _emit(runtime, sessionId, SessionEventTypes.sessionStarted, {
      'title': title,
    });

    final agent = resolveAdapter(installation.agentKind).start(
      AgentLaunch(
        workingDirectory: workingDirectory,
        installation: installation,
        permissionMode: permissionMode,
        resumeSessionId: resumeSessionId,
      ),
    );
    runtime.agent = agent;
    runtime.subscription = agent.events.listen(
      (event) => _emit(runtime, sessionId, event.type, event.data),
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

  SessionEvent _emit(
    _Runtime runtime,
    String sessionId,
    String type,
    Map<String, Object?> data,
  ) {
    final stored = eventDao.append(
      SessionEvent(
        sessionId: sessionId,
        seq: 0, // assigned by the DAO
        type: type,
        payload: jsonEncode(data),
        createdAt: clock.nowUtc(),
      ),
    );
    if (!runtime.controller.isClosed) runtime.controller.add(stored);
    return stored;
  }

  void _finish(String sessionId, SessionStatus defaultStatus) {
    final runtime = _runtimes.remove(sessionId);
    if (runtime == null) return;
    final status = runtime.finalStatus ?? defaultStatus;
    sessionDao.updateStatus(sessionId, status);
    _emit(runtime, sessionId, _lifecycleType(status), const {});
    runtime.subscription?.cancel();
    if (!runtime.controller.isClosed) runtime.controller.close();
    if (!runtime.done.isCompleted) runtime.done.complete();
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
  AgentSession? agent;
  StreamSubscription<AgentEvent>? subscription;
  SessionStatus? finalStatus;
}
