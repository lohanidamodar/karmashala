import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/mcp/tools/launch_tool_set.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_projects/store.dart' show RepositoryDao;
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// Every executable path answers present: the launch's own stat is not what
/// these tests are about.
final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// **A session can start a child anywhere**: in another project than its own,
/// or in a scratch folder with no project — and either way it is the
/// caller's child.
void main() {
  late RepoToolFixture fixture;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late LaunchToolSet tools;
  var ids = 0;

  setUp(() {
    ids = 0;
    fixture = RepoToolFixture();
    // The fixture's agent under the id this build launches.
    fixture.database.execute(
      "UPDATE agent_installations SET agent_kind = ? WHERE id = 'a1';",
      [AgentIds.claudeCode],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    final rows = CheckoutRows(fixture.database);
    final sessions = SessionDao(fixture.database);
    tools = LaunchToolSet(
      fixture.context,
      launches: ServerSessionLauncher(
        launcher: HostedAgentLauncher(
          registry: registry,
          sessions: sessions,
          mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
          now: () => RepoToolFixture.now,
          newId: () => 'new-${++ids}',
          hostEnvironment: const {},
          environmentOf: rows.environment,
        ),
        registry: registry,
        sessions: sessions,
        rows: rows,
        facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
        installationsIn: fixture.context.data.installationsIn,
        pathProbe: const _Everywhere(),
        directoryPresent: (_) => true,
        trustScratchFolder: (_, _) async {},
      ),
      reach: fixture.reach,
      folders: fixture.folders,
    );
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    fixture.dispose();
  });

  String projectOf(String sessionId) {
    final row = SessionDao(fixture.database).getById(sessionId)!;
    return RepositoryDao(fixture.database).getById(row.repositoryId)!.projectId;
  }

  test('in another project, as the caller\'s child', () async {
    final a = fixture.project('a', fixture.repository(fixture.path('a')));
    final b = fixture.project('b', fixture.repository(fixture.path('b')));
    fixture.session('caller', a.repositories.single.id);
    final bProject = b.repositories.single.projectId;

    final answer =
        (await tools.call('open_new_session', {
              'projectId': bProject,
              'title': 'Over in b',
            }, 'caller'))!
            as Map<String, Object?>;

    final child = SessionDao(fixture.database).getById('new-1')!;
    expect(answer['sessionId'], 'new-1');
    expect(child.parentSessionId, 'caller');
    expect(child.repositoryId, b.repositories.single.id);
    expect(projectOf('new-1'), bProject);
  });

  test(
    'with no project, in a scratch folder, as the caller\'s child',
    () async {
      final a = fixture.project('a', fixture.repository(fixture.path('a')));
      fixture.session('caller', a.repositories.single.id);

      await tools.call('open_new_session', {
        'scratch': true,
        'title': 'A side question',
      }, 'caller');

      final child = SessionDao(fixture.database).getById('new-1')!;
      expect(child.parentSessionId, 'caller');
      expect(projectOf('new-1'), isNot(a.repositories.single.projectId));
      final scratch = RepositoryDao(
        fixture.database,
      ).getById(child.repositoryId)!;
      expect(scratch.path.path, startsWith(fixture.home));
    },
  );
}
