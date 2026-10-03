import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
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
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;

  ExecutionEnvironment sshEnv() => ExecutionEnvironment(
    id: 'ssh:box',
    kind: EnvironmentKind.ssh,
    name: 'do-box',
    createdAt: testTime,
  );

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.connect();
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(sshEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.repositoryRows.insert(
      repository(
        id: 'r-remote',
        name: 'projects',
        environmentId: 'ssh:box',
        path: '/home/me/projects',
      ),
    );
    server.installationRows.insert(agentInstallation());
  });

  void addSession(String id, {required String repositoryId}) =>
      db.server.sessionRows.insert(
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
        dataClientProvider.overrideWithValue(data),
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

    expect(db.server.sessionRows.getById('s-remote'), isNull);
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
    expect(db.server.sessionRows.getById('s-local'), isNotNull);
    expect(mutator.deleted, isEmpty);
  });

  test('unchecking the CLI store removes the row either way', () async {
    addSession('s-local', repositoryId: 'r1');
    final (:container, :mutator) = mount();

    final notice = await container
        .read(sessionActionsProvider)
        .deleteNative('s-local', deleteFromCli: false);

    expect(db.server.sessionRows.getById('s-local'), isNull);
    expect(notice, isNull);
    expect(mutator.deleted, isEmpty);
  });

  test('an ACP session is removed with no CLI store to look in', () async {
    // Its conversation is the server's own rows; the CLI path refused it
    // with "The CLI session could not be identified".
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\npx.cmd',
      ),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's-acp',
        repositoryId: 'r1',
        agentInstallationId: 'acp',
        title: 'Over ACP',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: testTime,
      ),
    );
    final (:container, :mutator) = mount();

    final notice = await container
        .read(sessionActionsProvider)
        .deleteNative('s-acp');

    expect(db.server.sessionRows.getById('s-acp'), isNull);
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
