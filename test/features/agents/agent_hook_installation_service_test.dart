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

  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');

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
}
