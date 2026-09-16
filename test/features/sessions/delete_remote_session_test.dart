import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **Deleting a session whose CLI store is on another machine.**
///
/// `CliStoreLocator` walks this host and its WSL distributions and nothing
/// else, so a lookup for an SSH session's transcript comes back empty — which
/// is indistinguishable from a transcript that was already deleted. The single
/// delete treated that as a reason to refuse: the row stayed on screen and no
/// wording said why, so two sessions on a droplet could not be removed at all
/// (reported 2026-09-11). The row is ours and goes; the transcript on the
/// other machine is reported as left rather than claimed.
void main() {
  late AppDatabase db;

  ExecutionEnvironment sshEnv() => ExecutionEnvironment(
    id: 'ssh:box',
    kind: EnvironmentKind.ssh,
    name: 'do-box',
    createdAt: testTime,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(sshEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    RepositoryDao(db).insert(
      repository(
        id: 'r-remote',
        name: 'projects',
        environmentId: 'ssh:box',
        path: '/home/me/projects',
      ),
    );
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  void addSession(String id, {required String repositoryId}) =>
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: repositoryId,
          agentInstallationId: 'a1',
          title: 'New session',
          useWorktree: false,
          status: SessionStatus.unknown,
          createdAt: testTime,
          externalSessionId: 'ext-$id',
        ),
      );

  ({ProviderContainer container, _RecordingMutator mutator}) mount() {
    final mutator = _RecordingMutator();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        cliSessionMutatorProvider.overrideWithValue(mutator),
        cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, mutator: mutator);
  }

  test('a session on an SSH host is removed, and says what it left', () async {
    addSession('s-remote', repositoryId: 'r-remote');
    final (:container, :mutator) = mount();

    final notice = await container
        .read(sessionActionsProvider)
        .deleteNative('s-remote');

    expect(SessionDao(db).getById('s-remote'), isNull);
    expect(notice, contains('do-box'));
    expect(notice, contains('was left'));
    // Nothing on this machine was touched on that session's behalf.
    expect(mutator.deleted, isEmpty);
  });

  test('a local session still deletes through the CLI store', () async {
    addSession('s-local', repositoryId: 'r1');
    final (:container, :mutator) = mount();

    // No store to find it in, so the refusal stands for a *local* session:
    // its transcript is reachable, and a delete that silently kept it would
    // be the confident false statement.
    await expectLater(
      container.read(sessionActionsProvider).deleteNative('s-local'),
      throwsA(isA<StateError>()),
    );
    expect(SessionDao(db).getById('s-local'), isNotNull);
    expect(mutator.deleted, isEmpty);
  });

  test('unchecking the CLI store removes the row either way', () async {
    addSession('s-local', repositoryId: 'r1');
    final (:container, :mutator) = mount();

    final notice = await container
        .read(sessionActionsProvider)
        .deleteNative('s-local', deleteFromCli: false);

    expect(SessionDao(db).getById('s-local'), isNull);
    expect(notice, isNull);
    expect(mutator.deleted, isEmpty);
  });
}

class _RecordingMutator implements CliSessionMutator {
  final deleted = <String>[];

  @override
  Future<CliDeleteReport> delete(DetectedSession session) async {
    deleted.add(session.sessionId);
    return const CliDeleteReport(deleted: 1, failures: []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the remote-delete tests reach nothing else');
}
