import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_host/src/agents/server_model_catalogs.dart';
import 'package:karmashala_ssh/runner.dart' show buildRemoteCommandLine;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'agent_work_support.dart';

/// **Model lists, read by the server** in each installation's own
/// environment: cached for their time to live and across a restart, read
/// again on demand, and kept when a read fails. Every `agy` here is scripted.
void main() {
  final start = DateTime.utc(2026, 10, 12, 9);
  const wslId = 'wsl:Ubuntu';
  final sshId = sshEnvironmentId('h1');

  // `agy models`' stdout on 2026-10-12 (agy 1.3.3), trimmed.
  const agyModels =
      'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
      'agy-demo-high\tGemini 4 Argon (High)\n';

  late MutableClock clock;
  late AppDatabase db;
  late DataService service;
  late Map<String, ScriptedRunner> runners;
  late Map<String, CommandResult Function(CommandRequest)> answers;

  AgentInstallation agy(String id, String environmentId, String path) =>
      AgentInstallation(
        id: id,
        agentId: AgentIds.antigravity,
        executable: EnvironmentPath(environmentId: environmentId, path: path),
        createdAt: start,
      );

  ServerModelCatalogs catalogs() => ServerModelCatalogs(
    data: service,
    runnerFor: (environment) => runners[environment.id]!,
    clock: clock,
  );

  List<CommandRequest> asked(String environmentId) =>
      runners[environmentId]!.requests;

  setUp(() {
    clock = MutableClock(start);
    db = AppDatabase.memory();
    service = DataService(db, clock: () => clock.now);
    service.ensureEnvironment(localHostEnvironment(start));
    service.ensureEnvironment(
      ExecutionEnvironment(
        id: wslId,
        kind: EnvironmentKind.wsl,
        name: 'Ubuntu',
        wslDistribution: 'Ubuntu',
        createdAt: start,
      ),
    );
    service.ensureEnvironment(
      ExecutionEnvironment(
        id: sshId,
        kind: EnvironmentKind.ssh,
        name: 'build-box',
        sshHostId: 'h1',
        createdAt: start,
      ),
    );
    for (final (environmentId, row) in [
      (localHostEnvironmentId, agy('agy-host', localHostEnvironmentId, 'agy')),
      (wslId, agy('agy-wsl', wslId, '/home/me/.local/bin/agy')),
      (sshId, agy('agy-ssh', sshId, '/home/dev/.local/bin/agy')),
    ]) {
      service.reconcileProbe(
        environmentId: environmentId,
        readAt: start,
        found: [row],
        probed: const {},
        readings: const {},
      );
    }
    answers = {
      for (final id in [localHostEnvironmentId, wslId, sshId])
        id: (_) =>
            const CommandResult(exitCode: 0, stdout: agyModels, stderr: ''),
    };
    runners = {
      for (final id in [localHostEnvironmentId, wslId, sshId])
        id: ScriptedRunner(
          (request) => answers[id]!(request),
          environmentId: id,
        ),
    };
  });

  tearDown(() => db.close());

  test('reads `agy models` with the WSL installation\'s own binary', () async {
    final catalog = await catalogs().read('agy-wsl');
    final request = asked(wslId).single;
    expect(request.executable, '/home/me/.local/bin/agy');
    expect(request.arguments, ['models']);
    expect(asked(localHostEnvironmentId), isEmpty);
    expect(catalog.models.map((m) => m.id), [
      'gemini-3.8-flash-high',
      'agy-demo-high',
    ]);
    expect(catalog.models.last.label, 'Gemini 4 Argon (High)');
    expect(catalog.source, 'agy models');
    expect(catalog.readAt, start);
    expect(catalog.failure, isNull);
  });

  test('an SSH box is read over its own runner', () async {
    final catalog = await catalogs().read('agy-ssh');
    expect(asked(sshId).single.executable, '/home/dev/.local/bin/agy');
    expect(catalog.isLive, isTrue);
  });

  test('Codex\'s model cache on an SSH box is named for the remote shell to '
      'expand, through the line SSH really sends', () async {
    service.reconcileProbe(
      environmentId: sshId,
      readAt: start,
      found: [
        AgentInstallation(
          id: 'codex-ssh',
          agentId: AgentIds.codex,
          executable: EnvironmentPath(
            environmentId: sshId,
            path: '/home/dev/.local/bin/codex',
          ),
          createdAt: start,
        ),
      ],
      probed: const {},
      readings: const {},
    );
    const cache =
        '{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra",'
        '"visibility":"list"}]}';
    answers[sshId] = (_) =>
        const CommandResult(exitCode: 0, stdout: cache, stderr: '');
    final catalog = await catalogs().read('codex-ssh');
    expect(
      buildRemoteCommandLine(asked(sshId).single),
      "exec 'sh' '-c' 'cat \${CODEX_HOME:-\$HOME/.codex}/models_cache.json'",
    );
    expect(catalog.models.single.id, 'gpt-6-astra');
  });

  test('answers from the cache inside its time to live, and asks again '
      'after it or when told to', () async {
    final models = catalogs();
    await models.read('agy-host');
    clock.advance(const Duration(hours: 5));
    await models.read('agy-host');
    expect(asked(localHostEnvironmentId), hasLength(1));

    await models.read('agy-host', refresh: true);
    expect(asked(localHostEnvironmentId), hasLength(2));

    clock.advance(kAgentModelsTtl);
    final again = await models.read('agy-host');
    expect(asked(localHostEnvironmentId), hasLength(3));
    expect(again.readAt, clock.nowUtc());
  });

  test('a failed read keeps the last good list and says why', () async {
    final models = catalogs();
    await models.read('agy-wsl');
    clock.advance(const Duration(minutes: 1));
    answers[wslId] = (_) =>
        const CommandResult(exitCode: 1, stdout: '', stderr: 'offline');

    final kept = await models.read('agy-wsl', refresh: true);
    expect(kept.models, hasLength(2));
    expect(kept.readAt, start);
    expect(kept.failure, contains('agy models'));
    expect(kept.failedAt, clock.nowUtc());
  });

  test('a first read that fails has no list: the curated one stands', () async {
    answers[wslId] = (_) => throw CommandException('wsl.exe is gone');
    final none = await catalogs().read('agy-wsl');
    expect(none.isLive, isFalse);
    expect(none.failure, contains('wsl.exe is gone'));
  });

  test(
    'the last list survives a restart and is answered without a read',
    () async {
      await catalogs().read('agy-wsl');
      expect(asked(wslId), hasLength(1));

      final restarted = catalogs();
      final held = await restarted.read('agy-wsl');
      expect(asked(wslId), hasLength(1));
      expect(held.models.last.id, 'agy-demo-high');
      expect(held.readAt, start);
    },
  );

  test(
    'a switched account ages the list but keeps it as the fallback',
    () async {
      final models = catalogs();
      await models.read('agy-wsl');
      models.markStale('agy-wsl');
      answers[wslId] = (_) =>
          const CommandResult(exitCode: 1, stdout: '', stderr: '');
      final read = await models.read('agy-wsl');
      expect(asked(wslId), hasLength(2));
      expect(read.models, hasLength(2));
    },
  );

  test(
    'an agent with no lister lists none, and an unknown id is refused',
    () async {
      service.reconcileProbe(
        environmentId: localHostEnvironmentId,
        readAt: start,
        found: [
          agy('agy-host', localHostEnvironmentId, 'agy'),
          AgentInstallation(
            id: 'grok1',
            agentId: AgentIds.grok,
            executable: const EnvironmentPath(
              environmentId: localHostEnvironmentId,
              path: 'grok',
            ),
            createdAt: start,
          ),
        ],
        probed: const {},
        readings: const {},
      );
      final none = await catalogs().read('grok1');
      expect(none.source, isNull);
      expect(none.isLive, isFalse);
      expect(
        catalogs().read('nope'),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.notFound,
          ),
        ),
      );
    },
  );

  test('`agents.models` reaches it through the agent work', () async {
    final work = ServerAgentWork(
      data: service,
      runners: _Runners(runners),
      clock: clock,
      ids: CountingIds(),
      onItsOwn: false,
    )..attach();
    addTearDown(work.stop);
    final app = service.open((_) {});
    final reply = await app.handleLater(
      const AgentModelsRead('agy-wsl', refresh: true),
    );
    expect(reply.value.models.last.label, 'Gemini 4 Argon (High)');
    expect(asked(wslId), hasLength(1));
  });
}

class _Runners extends CommandRunnerFactory {
  const _Runners(this.byId);

  final Map<String, CommandRunner> byId;

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      byId[environment.id]!;
}
