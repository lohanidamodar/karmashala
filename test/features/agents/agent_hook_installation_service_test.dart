import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:chitragupta/src/features/agents/data/agent_hook_installer.dart';
import 'package:chitragupta/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/execution_environment.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Every store the locator would have found, without touching a real home.
class _StubLocator implements CliStoreLocator {
  _StubLocator(this.stores);

  final List<CliStore> stores;
  final visited = <String>[];

  @override
  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async {
    visited.addAll(environments.map((e) => e.id));
    return stores;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  late Directory claudeHome;

  // No switch address: the machine has no WSL adapter, or nothing was bound
  // on it. WSL is unreachable for this endpoint and must stay skipped.
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');
  const reachable = AgentHookEndpoint(
    port: 4242,
    token: 'tok',
    wslHost: '172.18.240.1',
  );

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    claudeHome = Directory.systemTemp.createTempSync('chitra_hooksvc_');
  });
  tearDown(() {
    db.close();
    claudeHome.deleteSync(recursive: true);
  });

  File settings() => File(p.join(claudeHome.path, 'settings.json'));

  ProviderContainer containerWith(_StubLocator locator) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cliStoreLocatorProvider.overrideWithValue(locator),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  String windowsEnvironmentId() => ExecutionEnvironmentDao(
    db,
  ).getAll().firstWhere((e) => e.kind == EnvironmentKind.windowsNative).id;

  _StubLocator windowsStore() => _StubLocator([
    CliStore(
      environmentId: windowsEnvironmentId(),
      homesByAgentId: {'claudeCode': claudeHome.path},
    ),
  ]);

  test('installs, then uninstalls exactly what it installed', () async {
    // The user's own hook, which has to survive both directions untouched.
    settings().writeAsStringSync(
      jsonEncode({
        'hooks': {
          'Stop': [
            {
              'hooks': [
                {'type': 'command', 'command': 'mine.sh'},
              ],
            },
          ],
        },
        'model': 'opus',
      }),
    );
    final service = containerWith(
      windowsStore(),
    ).read(agentHookInstallationServiceProvider);

    final installed = await service.installAll(endpoint);
    expect(installed.where((r) => r.installed), isNotEmpty);
    expect(settings().readAsStringSync(), contains(agentHookMarker));

    final removed = await service.uninstallAll();

    expect(
      removed.where((r) => r.installed),
      isNotEmpty,
      reason: 'the sweep has to report the configs it actually rewrote',
    );
    final after = settings().readAsStringSync();
    expect(
      after,
      isNot(contains(agentHookMarker)),
      reason:
          'a hook left behind keeps running curl at a dead port after the '
          'app quits, and outlives uninstalling the app',
    );
    expect(after, contains('mine.sh'));
    expect(after, contains('"model"'));
  });

  test('uninstalling twice is a no-op the second time', () async {
    final service = containerWith(
      windowsStore(),
    ).read(agentHookInstallationServiceProvider);
    await service.installAll(endpoint);
    await service.uninstallAll();
    final raw = settings().readAsStringSync();

    final again = await service.uninstallAll();

    expect(again.every((r) => !r.installed), isTrue);
    expect(settings().readAsStringSync(), raw);
  });

  test('uninstall sweeps environments install skipped', () async {
    // WSL is skipped on install (loopback is not reachable from a distro), but
    // an entry an older build wrote there is still ours to remove.
    settings().writeAsStringSync(
      jsonEncode({
        'hooks': {
          'Stop': [
            {
              'hooks': [
                {'type': 'command', 'command': 'curl … $agentHookMarker …'},
              ],
            },
          ],
        },
      }),
    );
    final wsl = wslEnv();
    ExecutionEnvironmentDao(db).upsert(wsl);
    final locator = _StubLocator([
      CliStore(
        environmentId: wsl.id,
        homesByAgentId: {'claudeCode': claudeHome.path},
      ),
    ]);
    final service = containerWith(
      locator,
    ).read(agentHookInstallationServiceProvider);

    final before = settings().readAsStringSync();
    await service.installAll(endpoint);
    expect(
      settings().readAsStringSync(),
      before,
      reason: 'install must not write into a WSL config at all',
    );

    await service.uninstallAll();

    expect(settings().readAsStringSync(), isNot(contains(agentHookMarker)));
  });

  group('a WSL store the endpoint can reach', () {
    /// A store in [wsl], pointed at the same temp home. Only the environment
    /// kind is under test; the file is a fixture either way.
    (_StubLocator, ExecutionEnvironment) wslStore() {
      final wsl = wslEnv();
      ExecutionEnvironmentDao(db).upsert(wsl);
      return (
        _StubLocator([
          CliStore(
            environmentId: wsl.id,
            homesByAgentId: {'claudeCode': claudeHome.path},
          ),
        ]),
        wsl,
      );
    }

    test('is installed, at the switch address', () async {
      final (locator, wsl) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);

      final results = await service.installAll(reachable);

      final claude = results.singleWhere((r) => r.environmentId == wsl.id);
      expect(claude.installed, isTrue);
      expect(claude.skippedBecause, isNull);
      final raw = settings().readAsStringSync();
      expect(raw, contains('172.18.240.1:4242/agent-hook'));
      expect(raw, isNot(contains('127.0.0.1')));
    });

    test('is skipped, truthfully, when there is no switch address', () async {
      final (locator, wsl) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);

      final results = await service.installAll(endpoint);

      final claude = results.singleWhere((r) => r.environmentId == wsl.id);
      expect(claude.installed, isFalse);
      expect(claude.skippedBecause, contains('no callback address this app binds is reachable'));
      expect(claude.skippedBecause, contains('state file'));
      expect(settings().existsSync(), isFalse);
    });

    test('an SSH store is still skipped, switch address or not', () async {
      // Another machine entirely: nothing this app binds can be dialled from
      // there, and binding something that could would put the whole tool
      // surface on the network.
      final ssh = sshEnvFixture();
      ExecutionEnvironmentDao(db).upsert(ssh);
      final service = containerWith(
        _StubLocator([
          CliStore(
            environmentId: ssh.id,
            homesByAgentId: {'claudeCode': claudeHome.path},
          ),
        ]),
      ).read(agentHookInstallationServiceProvider);

      final results = await service.installAll(reachable);

      expect(results.single.installed, isFalse);
      expect(results.single.skippedBecause, contains('no callback address this app binds is reachable'));
      expect(settings().existsSync(), isFalse);
    });

    test('uninstall sweeps it after the switch address changes', () async {
      // The port is ephemeral and the switch address can move between boots, so
      // the sweep must match on what we *marked*, not on what we wrote.
      final (locator, _) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);
      await service.installAll(reachable);
      expect(settings().readAsStringSync(), contains('172.18.240.1'));

      await service.installAll(
        const AgentHookEndpoint(
          port: 5555,
          token: 'tok2',
          wslHost: '172.30.16.1',
        ),
      );
      expect(settings().readAsStringSync(), contains('172.30.16.1'));

      await service.uninstallAll();

      final after = settings().readAsStringSync();
      expect(after, isNot(contains(agentHookMarker)));
      expect(after, isNot(contains('172.18.240.1')));
      expect(after, isNot(contains('172.30.16.1')));
    });

    test('uninstall sweeps it when the switch address has gone', () async {
      // Next launch, no WSL adapter: install skips this store, and the sweep
      // still has to take out what the previous launch wrote.
      final (locator, _) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);
      await service.installAll(reachable);

      await service.installAll(endpoint);
      await service.uninstallAll();

      expect(settings().readAsStringSync(), isNot(contains(agentHookMarker)));
    });

    test('ten launches leave exactly one entry per event', () async {
      final (locator, _) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);
      // The user's own hook, which every one of the ten must leave alone.
      settings().writeAsStringSync(
        jsonEncode({
          'hooks': {
            'Stop': [
              {
                'hooks': [
                  {'type': 'command', 'command': 'mine.sh'},
                ],
              },
            ],
          },
        }),
      );

      for (var launch = 0; launch < 10; launch++) {
        // A fresh ephemeral port each time, as a real relaunch gets.
        await service.installAll(
          AgentHookEndpoint(
            port: 40000 + launch,
            token: 'tok$launch',
            wslHost: '172.18.240.1',
          ),
        );
      }

      final hooks =
          (jsonDecode(settings().readAsStringSync()) as Map)['hooks'] as Map;
      for (final entry in hooks.entries) {
        final ours = [
          for (final matcher in entry.value as List)
            for (final hook in (matcher as Map)['hooks'] as List)
              if ('${(hook as Map)['command']}'.contains(agentHookMarker))
                hook['command'],
        ];
        expect(ours, hasLength(1), reason: '${entry.key}');
        expect(ours.single, contains(':40009/agent-hook'));
      }
      expect(settings().readAsStringSync(), contains('mine.sh'));
    });
  });

  test('one unparseable config does not stop or corrupt the others', () async {
    // Two stores, and the first cannot be read. The walk has to finish, the
    // reachable store has to be written, and the broken file has to be left
    // exactly as it was — it is somebody's real settings.json.
    final broken = Directory.systemTemp.createTempSync('chitra_hooksvc_bad_');
    addTearDown(() => broken.deleteSync(recursive: true));
    final brokenConfig = File(p.join(broken.path, 'settings.json'));
    brokenConfig.writeAsStringSync('{ not json');
    final wsl = wslEnv();
    ExecutionEnvironmentDao(db).upsert(wsl);
    final service = containerWith(
      _StubLocator([
        CliStore(
          environmentId: wsl.id,
          homesByAgentId: {'claudeCode': broken.path},
        ),
        CliStore(
          environmentId: windowsEnvironmentId(),
          homesByAgentId: {'claudeCode': claudeHome.path},
        ),
      ]),
    ).read(agentHookInstallationServiceProvider);

    final results = await service.installAll(reachable);

    expect(brokenConfig.readAsStringSync(), '{ not json');
    expect(
      broken.listSync().map((e) => p.basename(e.path)).toList(),
      ['settings.json'],
      reason: 'nothing staged beside a config we could not read',
    );
    final failed = results.singleWhere((r) => r.environmentId == wsl.id);
    expect(failed.installed, isFalse);
    expect(failed.skippedBecause, contains('FormatException'));
    final good = results.singleWhere(
      (r) => r.environmentId == windowsEnvironmentId(),
    );
    expect(good.installed, isTrue);
    expect(settings().readAsStringSync(), contains(agentHookMarker));
  });
}
