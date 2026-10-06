import 'dart:async';

import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala/src/features/sessions/application/session_engine.dart';
import 'package:karmashala/src/features/sessions/application/session_engine_provider.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/application/git_providers.dart';
import 'package:karmashala/src/features/git/data/git_data.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala/src/core/data/data_client.dart';

/// What quitting has to end, beyond the components the lifecycle owner builds
/// itself.
///
/// `ref.onDispose` takes a callback, not a future, so Riverpod starts a
/// teardown and immediately forgets it. That is fine for a field being nulled
/// and wrong for anything that ends a process or closes a socket: on quit,
/// `windowManager.destroy()` runs the moment the shutdown sequence returns.
/// Before Loop 65 the session engine had no teardown at all — `_finish` is
/// driven by the agent's own stream closing, which on quit never happens — so
/// the agent CLIs outlived the app that started them.
void main() {
  late FakeDataServer server;
  late Override data;
  late SessionsData sessions;
  late SessionRecordsData records;
  late DataClient client;

  setUp(() async {
    server = FakeDataServer();
    data = await server.override();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    client = await server.connect();
    sessions = SessionsData(client);
    records = SessionRecordsData(client);
  });

  SessionEngine buildEngine(ChatProtocolResolver resolver) => SessionEngine(
    sessions: sessions,
    records: records,
    worktreeService: WorktreesClient(GitData(client), WorktreeCreations()),
    resolveProtocol: resolver,
    clock: FixedClock(testTime),
    ids: SequentialIdGenerator(),
  );

  group('SessionEngine.dispose', () {
    test('stops every live agent and empties the runtimes', () async {
      final adapter = _RecordingAdapter();
      final engine = buildEngine((_) => adapter);
      final session = await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );
      expect(engine.isActive(session.id), isTrue);
      final done = engine.whenDone(session.id)!;

      await engine.dispose();

      expect(adapter.sessions.single.stopped, isTrue);
      expect(engine.activeSessionIds, isEmpty);
      expect(engine.isActive(session.id), isFalse);
      // Anyone waiting on the run is released rather than left hanging.
      await done;
    });

    test('records nothing: the app ended, the session did not', () async {
      final adapter = _RecordingAdapter();
      final engine = buildEngine((_) => adapter);
      final session = await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );
      await sessions.settled();
      final eventsBefore = server.eventRows.countForSession(session.id);

      await engine.dispose();
      await sessions.settled();

      expect(
        server.sessionRows.getById(session.id)!.status,
        SessionStatus.running,
        reason: 'a run that was interrupted by a quit was not cancelled',
      );
      expect(server.eventRows.countForSession(session.id), eventsBefore);
    });

    test('is idempotent', () async {
      final adapter = _RecordingAdapter();
      final engine = buildEngine((_) => adapter);
      await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );

      await Future.wait([engine.dispose(), engine.dispose()]);
      await engine.dispose();

      expect(adapter.sessions.single.stopCalls, 1);
    });
  });

  group('the shutdown waits for what Riverpod drops', () {
    test('the session engine is stopped, and awaited', () async {
      final gate = Completer<void>();
      final adapter = _RecordingAdapter(gate: gate.future);
      final container = ProviderContainer(
        overrides: [
          data,
          chatProtocolResolverProvider.overrideWithValue((_) => adapter),
          agentHookInstallationServiceProvider.overrideWith(
            _InertHookService.new,
          ),
        ],
      );
      final engine = container.read(sessionEngineProvider);
      await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );
      final lifecycle = AppLifecycle(container);

      var finished = false;
      final shutdown = lifecycle.shutdown().whenComplete(() => finished = true);
      await pumpEventQueue();

      expect(
        finished,
        isFalse,
        reason: 'the agent process has not gone away yet',
      );

      gate.complete();
      await shutdown;

      expect(adapter.sessions.single.stopped, isTrue);
      expect(engine.activeSessionIds, isEmpty);
    });

  });
}

/// The real service would retire the endpoints in the agent stores the real
/// locator finds — the developer's own `~/.claude`, `~/.codex` and `~/.gemini`.
class _InertHookService extends AgentHookInstallationService {
  _InertHookService(super.ref);

  @override
  Future<List<AgentHookInstallation>> retireEndpoints() async => const [];
}

/// An adapter whose sessions record being stopped, and can be made to take
/// their time about it.
class _RecordingAdapter implements AgentChatProtocol {
  _RecordingAdapter({this.gate});

  /// Held until this completes, standing in for a child process that does not
  /// die the instant it is asked to.
  final Future<void>? gate;

  final sessions = <_RecordingSession>[];

  @override
  String get agentId => 'fake';

  @override
  AgentSession start(AgentLaunch launch) {
    final session = _RecordingSession(gate);
    sessions.add(session);
    return session;
  }
}

class _RecordingSession implements AgentSession {
  _RecordingSession(this._gate);

  final Future<void>? _gate;
  final _controller = StreamController<AgentEvent>();

  bool stopped = false;
  int stopCalls = 0;

  @override
  Stream<AgentEvent> get events => _controller.stream;

  @override
  Future<void> send(String message) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    if (_gate != null) await _gate;
    stopped = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

/// A pool whose close can be held open, so a test can see whether the shutdown
/// waits for it or merely starts it.
