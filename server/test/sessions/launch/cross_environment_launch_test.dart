import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// Round 127: an installation is the pair (agent, environment), so an agent
/// runs where it is installed, whichever environment its checkout was
/// registered in. A conversation from a WSL store merges into a Windows
/// project; it still resumes in WSL, from `/mnt/c/…`.
void main() {
  final t0 = DateTime.utc(2026, 10, 31, 12);
  const wsl = 'wsl:archlinux';
  const windowsFolder = r'C:\src\kheti';
  const wslFolder = '/mnt/c/src/kheti';
  const conversation = 'ddc90de8';
  const windowsPath = EnvironmentPath(
    environmentId: 'windows',
    path: windowsFolder,
  );
  const wslPath = EnvironmentPath(environmentId: wsl, path: wslFolder);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late ServerSessionLauncher launches;
  late SessionDao sessions;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, wsl_distribution, '
      'ssh_host_id, created_at) VALUES (?, ?, ?, ?, ?, ?), '
      '(?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'windows', 'windowsNative', 'Windows', null, null, '$t0', //
        wsl, 'wsl', 'archlinux', 'archlinux', null, '$t0', //
        'wsl:Ubuntu', 'wsl', 'Ubuntu', 'Ubuntu', null, '$t0', //
        'box', 'ssh', 'Box', null, 'h1', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), '
      '(?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'win-repo', 'p1', 'kheti', 'windows', windowsFolder, '$t0', //
        'wsl-repo', 'p2', 'kheti', wsl, wslFolder, '$t0', //
        'share-repo', 'p3', 'share', 'windows', r'\\nas\src', '$t0', //
        'home-repo', 'p4', 'home', wsl, '/home/me/app', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), '
      '(?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'agy-wsl', AgentIds.antigravity, wsl, '/home/me/bin/agy', '$t0', 1, //
        'in-wsl', AgentIds.codex, wsl, '/home/me/.local/bin/codex', '$t0', 1, //
        'in-windows', AgentIds.codex, 'windows', r'C:\bin\codex.exe', '$t0', 1,
        'in-ubuntu', AgentIds.codex, 'wsl:Ubuntu', '/usr/bin/codex', '$t0', 1,
        'on-box', AgentIds.codex, 'box', '/usr/bin/codex', '$t0', 1,
      ],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    sessions = SessionDao(database);
    final rows = CheckoutRows(database);
    var ids = 0;
    launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: sessions,
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        windows: true,
      ),
      registry: registry,
      sessions: sessions,
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: true),
      installationsIn: DataService(database).installationsIn,
      directoryPresent: (_) => true,
      pathProbe: const _Everywhere(),
    );
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  /// What the import and an earlier resume left: a stopped row, as written.
  void stopped({
    String id = 'written',
    String repositoryId = 'win-repo',
    String installationId = 'in-wsl',
    EnvironmentPath? directory = windowsPath,
    EnvironmentPath? worktree,
  }) => sessions.insertWithPrimaryRepository(
    Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: installationId,
      title: 'Written',
      useWorktree: worktree != null,
      worktree: worktree,
      workingDirectory: directory,
      status: SessionStatus.failed,
      createdAt: t0,
      externalSessionId: conversation,
    ),
  );

  List<String> wslPrefix(String folder, [String distro = 'archlinux']) => [
    'wsl.exe',
    '-d',
    distro,
    '--cd',
    folder,
    '--',
  ];

  group('a conversation from another environment\'s store', () {
    test(
      'resumes in WSL under a Windows checkout, and the row says so',
      () async {
        final started = await launches.start(
          const SessionStartSpec(
            repositoryId: 'win-repo',
            installationId: 'in-wsl',
            title: 'From WSL',
            resumeConversationId: conversation,
          ),
        );

        expect(pty.started.single.argv.take(6), wslPrefix(wslFolder));
        expect(pty.started.single.argv[6], '/home/me/.local/bin/codex');
        expect(pty.started.single.workingDirectory, isNull);
        expect(sessions.getById(started.sessionId)!.workingDirectory, wslPath);
        expect(started.workingDirectoryNotice, isNull);
      },
    );

    test('and the reverse: a Windows store under a WSL checkout', () async {
      final started = await launches.start(
        const SessionStartSpec(
          repositoryId: 'wsl-repo',
          installationId: 'in-windows',
          title: 'From Windows',
          resumeConversationId: conversation,
        ),
      );

      expect(pty.started.single.argv.first, isNot('wsl.exe'));
      expect(pty.started.single.workingDirectory, windowsFolder);
      expect(
        sessions.getById(started.sessionId)!.workingDirectory,
        windowsPath,
      );
    });
  });

  group('a row already written with the wrong environment', () {
    test('heals on a resume, whoever asks for it, and stays healed', () async {
      stopped();

      await launches.resume('written');

      expect(pty.started.single.argv.take(6), wslPrefix(wslFolder));
      expect(sessions.getById('written')!.workingDirectory, wslPath);

      await launches.resume('written', restart: true);

      expect(pty.started, hasLength(2));
      expect(pty.started.last.argv.take(6), wslPrefix(wslFolder));
      expect(sessions.getById('written')!.workingDirectory, wslPath);
    });

    test('heals when a client names it, as open and send do', () async {
      stopped();

      final started = await launches.start(
        const SessionStartSpec(
          repositoryId: 'win-repo',
          installationId: 'in-wsl',
          title: 'Written',
          resumeConversationId: conversation,
          workingDirectory: windowsPath,
        ),
      );

      expect(started.sessionId, 'written');
      expect(pty.started.single.argv.take(6), wslPrefix(wslFolder));
      expect(sessions.getById('written')!.workingDirectory, wslPath);
    });

    test('with no directory recorded, heals from the checkout', () async {
      stopped(directory: null);

      await launches.resume('written');

      expect(pty.started.single.argv.take(6), wslPrefix(wslFolder));
      expect(sessions.getById('written')!.workingDirectory, wslPath);
    });

    test('a directory below the checkout keeps its place', () async {
      stopped(
        directory: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\kheti\game',
        ),
      );

      await launches.resume('written');

      expect(pty.started.single.argv.take(6), wslPrefix('$wslFolder/game'));
      expect(
        sessions.getById('written')!.workingDirectory,
        const EnvironmentPath(environmentId: wsl, path: '$wslFolder/game'),
      );
    });

    test('its worktree is reached the same way', () async {
      const tree = EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\.trees\one',
      );
      stopped(directory: null, worktree: tree);

      await launches.resume('written');

      expect(
        pty.started.single.argv.take(6),
        wslPrefix('/mnt/c/src/.trees/one'),
      );
    });

    test('Antigravity is no different from any other agent', () async {
      stopped(installationId: 'agy-wsl');

      await launches.resume('written');

      expect(pty.started.single.argv.take(6), wslPrefix(wslFolder));
      expect(pty.started.single.argv[6], '/home/me/bin/agy');
      expect(sessions.getById('written')!.workingDirectory, wslPath);
    });

    test('a fork of it starts where the agent is installed', () async {
      stopped();

      final started = await launches.start(
        const SessionStartSpec(
          repositoryId: 'win-repo',
          installationId: 'in-wsl',
          title: 'Written (fork)',
          forkConversationId: conversation,
          workingDirectory: windowsPath,
        ),
      );

      expect(pty.started.single.argv.take(6), wslPrefix(wslFolder));
      expect(sessions.getById(started.sessionId)!.workingDirectory, wslPath);
    });
  });

  group('a launch whose folder cannot be said where the agent runs', () {
    Future<void> refused(
      SessionStartSpec spec,
      Object matcher, {
      int rowsAfter = 0,
    }) async {
      await expectLater(
        launches.start(spec),
        throwsA(isA<StateError>().having((e) => e.message, 'message', matcher)),
      );
      expect(pty.started, isEmpty);
      expect(sessions.getAll(), hasLength(rowsAfter));
    }

    test(
      'a network share has no WSL path',
      () => refused(
        const SessionStartSpec(
          repositoryId: 'share-repo',
          installationId: 'in-wsl',
          title: 'Share',
        ),
        allOf(contains('archlinux'), contains(r'\\nas\src')),
      ),
    );

    test(
      'an SSH box cannot see this machine',
      () => refused(
        const SessionStartSpec(
          repositoryId: 'win-repo',
          installationId: 'on-box',
          title: 'Box',
        ),
        allOf(contains('Box'), contains(windowsFolder)),
      ),
    );

    test(
      'one distribution\'s home is not another\'s',
      () => refused(
        const SessionStartSpec(
          repositoryId: 'home-repo',
          installationId: 'in-ubuntu',
          title: 'Other distro',
        ),
        allOf(contains('Ubuntu'), contains('/home/me/app')),
      ),
    );

    test('a recorded directory is held to the same rule', () async {
      stopped(
        directory: const EnvironmentPath(
          environmentId: 'windows',
          path: r'\\nas\src',
        ),
      );

      await refused(
        const SessionStartSpec(
          repositoryId: 'win-repo',
          installationId: 'in-wsl',
          title: 'Written',
          resumeConversationId: conversation,
        ),
        contains(r'\\nas\src'),
        rowsAfter: 1,
      );
      expect(sessions.getById('written')!.status, SessionStatus.failed);
    });

    test(
      'a new worktree is made where the checkout lives, so it is refused '
      'rather than started in a folder the agent cannot read',
      () => refused(
        const SessionStartSpec(
          repositoryId: 'win-repo',
          installationId: 'in-wsl',
          title: 'Tree',
          worktree: true,
        ),
        allOf(contains('worktree'), contains('archlinux')),
      ),
    );
  });

  test('an agent installed beside its checkout is not touched', () async {
    final started = await launches.start(
      const SessionStartSpec(
        repositoryId: 'win-repo',
        installationId: 'in-windows',
        title: 'Plain',
      ),
    );

    expect(pty.started.single.workingDirectory, windowsFolder);
    expect(sessions.getById(started.sessionId)!.workingDirectory, windowsPath);
  });
}
