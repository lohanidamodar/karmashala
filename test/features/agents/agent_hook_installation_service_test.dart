import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_installer.dart';
import 'package:karmashala/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
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
    claudeHome = Directory.systemTemp.createTempSync('karmashala_hooksvc_');
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

  /// The bootstrapped local host, whichever OS the suite is running on.
  ///
  /// Not `kind == windowsNative`: on a Mac the host row is `localPosix`, and
  /// this used to throw `Bad state: No element` before the store was ever
  /// looked at. These cases are about a **local** store, not a Windows one —
  /// the WSL and SSH cases below name their environments explicitly.
  String localEnvironmentId() => ExecutionEnvironmentDao(
    db,
  ).getAll().firstWhere((e) => isLocalHost(e.kind)).id;

  _StubLocator localStore() => _StubLocator([
    CliStore(
      environmentId: localEnvironmentId(),
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
      localStore(),
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
      localStore(),
    ).read(agentHookInstallationServiceProvider);
    await service.installAll(endpoint);
    await service.uninstallAll();
    final raw = settings().readAsStringSync();

    final again = await service.uninstallAll();

    expect(again.every((r) => !r.installed), isTrue);
    expect(settings().readAsStringSync(), raw);
  });

  test('install clears what it cannot deliver to, without adding one', () async {
    // WSL is unreachable over loopback, so nothing of ours may be written
    // here. This used to assert the file came back *byte-identical*, which
    // sounded like restraint and was actually the bug: an entry an older
    // build left behind survived every launch, and only an explicit
    // uninstall could clear it. Meanwhile it fired on every prompt.
    //
    // The guarantee that mattered is intact — install adds no hook to a
    // config it cannot deliver to — and the stale one no longer outlives it.
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

    await service.installAll(endpoint);

    final after = settings().readAsStringSync();
    expect(
      after,
      isNot(contains(agentHookMarker)),
      reason: 'the entry that was failing on every prompt is gone',
    );
    expect(
      after,
      isNot(contains('127.0.0.1')),
      reason: 'and install still wrote no hook of its own here',
    );

    // Still a no-op afterwards: the sweep has nothing left to find.
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

    test('a hook left by an earlier run is removed, not left to fail', () async {
      // The owner upgraded, and every prompt in their WSL session printed
      // `curl: (52) Empty reply from server` followed by a failed hook. The
      // entry was written by an older build — a noisier command, and an
      // address that no longer answers — and skipping only ever decided what
      // *not* to write, so nothing in the app could reach in and clear it.
      // An unreachable environment must end this sweep with none of our hooks
      // in it, not with a stale one nobody can remove.
      final (locator, wsl) = wslStore();
      settings().writeAsStringSync(
        jsonEncode({
          'hooks': {
            'SessionEnd': [
              {
                'hooks': [
                  {
                    'type': 'command',
                    'command':
                        'curl -sS -m 2 -X POST --data-binary @- '
                        '"http://172.18.240.1:9999/agent-hook'
                        '?marker=$agentHookMarker"',
                  },
                ],
              },
            ],
            'UserPromptSubmit': [
              {
                'hooks': [
                  {'type': 'command', 'command': 'echo mine'},
                ],
              },
            ],
          },
        }),
      );

      final results = await containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider).installAll(endpoint);

      final claude = results.singleWhere((r) => r.environmentId == wsl.id);
      expect(claude.installed, isFalse);
      expect(
        claude.skippedBecause,
        contains('left here by an earlier run was removed'),
      );
      final raw = settings().readAsStringSync();
      expect(
        raw,
        isNot(contains(agentHookMarker)),
        reason: 'the entry that was failing on every prompt is gone',
      );
      expect(
        raw,
        contains('echo mine'),
        reason: "the user's own hook is not ours to remove",
      );
    });

    test('an unreachable Codex store gets no script either', () async {
      // Codex is the one agent whose callback address lives in a **file we
      // write**, not only in the command. So an environment the endpoint cannot
      // reach has two things to stay clear of, and the sweep has to remove
      // both: an entry an earlier run left is a hook that fires and never
      // arrives, and a script left beside it is a bearer token in somebody's
      // home directory answering to nobody.
      final wsl = wslEnv();
      ExecutionEnvironmentDao(db).upsert(wsl);
      final codexHome = Directory(p.join(claudeHome.path, '.codex'))
        ..createSync(recursive: true);
      final script = File(p.join(codexHome.path, '$agentHookMarker.sh'))
        ..writeAsStringSync('#!/bin/sh\ncurl -s "http://172.18.240.1:9999/"\n');

      final results = await containerWith(
        _StubLocator([
          CliStore(
            environmentId: wsl.id,
            homesByAgentId: {'codex': codexHome.path},
          ),
        ]),
      ).read(agentHookInstallationServiceProvider).installAll(endpoint);

      final codex = results.singleWhere((r) => r.agentId == 'codex');
      expect(codex.installed, isFalse);
      expect(
        codex.skippedBecause,
        contains('no callback address this app binds is reachable'),
      );
      expect(script.existsSync(), isFalse);
      expect(File(p.join(codexHome.path, 'hooks.json')).existsSync(), isFalse);
    });

    test('an unreachable store with nothing of ours is left alone', () async {
      // The common case, and the one that must not start writing files: no
      // entry of ours means nothing to clean, and a config we never touched
      // stays untouched.
      final (locator, _) = wslStore();

      await containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider).installAll(endpoint);

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
    final broken = Directory.systemTemp.createTempSync('karmashala_hooksvc_bad_');
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
          environmentId: localEnvironmentId(),
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
      (r) => r.environmentId == localEnvironmentId(),
    );
    expect(good.installed, isTrue);
    expect(settings().readAsStringSync(), contains(agentHookMarker));
  });
}
