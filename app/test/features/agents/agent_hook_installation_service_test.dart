import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_spool_drainer.dart';

import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import 'package:agent_cli/read.dart';

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

  // Everything this endpoint has is about the loopback listener, and that is
  // the point: a WSL agent's transport does not read one of these fields, so a
  // launch that never saw a WSL switch address still installs WSL hooks that
  // work. SSH is the environment that gets nothing, and it is not a matter of
  // which addresses came up.
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    claudeHome = Directory.systemTemp.createTempSync('karmashala_hooksvc_');
  });
  tearDown(() {
    db.close();
    removeTempDirectory(claudeHome);
  });

  File settings() => File(p.join(claudeHome.path, 'settings.json'));
  File endpointFile() =>
      File(p.join(claudeHome.path, '$agentHookMarker.endpoint'));

  /// The container the service runs in.
  ///
  /// Nothing is stubbed but the store locator. There used to be a reachability
  /// probe here as well, standing in for a `curl` run inside a distribution;
  /// the transport it was probing is gone, and with it the need for any WSL
  /// case in this file to depend on the suite's machine having WSL.
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

  /// **A machine with no WSL, pinned end to end.**
  ///
  /// Every measurement behind the spool transport was taken on Windows against
  /// a real distribution, and this app also ships on macOS and Linux where none
  /// of it exists — no distribution, no `\\wsl.localhost` share, no interop. So
  /// the absence case is asserted rather than assumed, because a regression
  /// here would be invisible on the machine the work was done on and obvious on
  /// the owner's Mac.
  ///
  /// What must hold: a local store keeps the loopback HTTP transport it has
  /// today, byte for byte; nothing spooling is created beside it; and the
  /// drainer is handed an empty list, which runs no timer and therefore never
  /// reaches for a share that is not there.
  test('an agent that is not installed here is skipped, not blamed', () async {
    // The real shape: a Mac with the Antigravity IDE (`~/.gemini/antigravity`)
    // but not its CLI (`~/.gemini/antigravity-cli`). There is no agent here to
    // hook, which is the one way `install` can answer `false` without anything
    // being wrong — and it was reported as though something were, on every
    // launch: "Wrote antigravity hooks in macOS but the config does not carry
    // them ... another process rewriting <path> is the usual cause."
    final missing = p.join(claudeHome.path, 'not-installed', 'antigravity-cli');

    final results = await containerWith(
      _StubLocator([
        CliStore(
          environmentId: localEnvironmentId(),
          homesByAgentId: {'claudeCode': missing},
        ),
      ]),
    ).read(agentHookInstallationServiceProvider).installAll(endpoint);

    final row = results.single;
    expect(row.installed, isFalse);
    expect(
      row.skippedBecause,
      'the agent is not installed in this environment',
      reason: 'not "something else rewrote the config", which is a defect',
    );
    // Recorded, but not a fault: the row says why, and nothing may show it as
    // a degraded environment.
    expect(row.agentPresent, isFalse);
    expect(
      AgentHookInstallationReport([row]).skippedByEnvironment,
      isEmpty,
      reason: 'an agent nobody installed is not this machine failing',
    );
    // And nothing was created for an agent that is not here.
    expect(Directory(missing).existsSync(), isFalse);
  });

  group('a machine with no WSL is untouched by any of this', () {
    test('a local store keeps the URL-and-token endpoint file', () async {
      final service = containerWith(
        localStore(),
      ).read(agentHookInstallationServiceProvider);

      await service.installAll(endpoint);

      final written = endpointFile().readAsStringSync();
      expect(written, contains('url=http://127.0.0.1:4242/agent-hook'));
      expect(written, contains('token=tok'));
      expect(
        written,
        isNot(contains('spool=')),
        reason:
            'the spool is for an environment that cannot dial us, and a local '
            'agent is a child process on this very machine',
      );
    });

    test('nothing spooling is created beside a local store', () async {
      final service = containerWith(
        localStore(),
      ).read(agentHookInstallationServiceProvider);

      await service.installAll(endpoint);

      final left = claudeHome
          .listSync()
          .map((e) => p.basename(e.path))
          .where((name) => name.contains('spool'))
          .toList();
      expect(left, isEmpty, reason: 'left behind: $left');
    });

    test('the drainer is given nothing, and so polls nothing', () async {
      final service = containerWith(
        localStore(),
      ).read(agentHookInstallationServiceProvider);

      final report = AgentHookInstallationReport(
        await service.installAll(endpoint),
      );

      expect(report.spoolSources, isEmpty);

      // The lifecycle owner hands exactly this to the drainer. An empty list
      // has to *stop* it rather than run it over nothing: a macOS host would
      // otherwise wake every 400 ms for the life of the process to discover
      // there is nothing to read.
      var asked = 0;
      final drainer = AgentHookSpoolDrainer(
        onEvent: (_) => fail('there is nothing to drain'),
        runningDistributions: () async {
          asked++;
          return const {};
        },
      );
      addTearDown(drainer.dispose);

      drainer.watch(report.spoolSources);
      await drainer.drainOnce();

      expect(drainer.sources, isEmpty);
      expect(
        asked,
        0,
        reason:
            'off Windows there is no `wsl.exe` to ask, and asking would be a '
            'ProcessException every tick',
      );
    });
  });

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
    expect(
      revealHookCommands(settings().readAsStringSync()),
      contains(agentHookMarker),
    );

    final removed = await service.uninstallAll();

    expect(
      removed.where((r) => r.installed),
      isNotEmpty,
      reason: 'the sweep has to report the configs it actually rewrote',
    );
    final after = settings().readAsStringSync();
    expect(
      revealHookCommands(after),
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
    // An SSH host shares neither a loopback nor a filesystem with this
    // process, so nothing of ours may be written there. This used to assert
    // the file came back *byte-identical*, which sounded like restraint and
    // was actually the bug: an entry an older build left behind survived every
    // launch, and only an explicit uninstall could clear it. Meanwhile it
    // fired on every prompt.
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
    final ssh = sshEnvFixture();
    ExecutionEnvironmentDao(db).upsert(ssh);
    final locator = _StubLocator([
      CliStore(
        environmentId: ssh.id,
        homesByAgentId: {'claudeCode': claudeHome.path},
      ),
    ]);
    final service = containerWith(
      locator,
    ).read(agentHookInstallationServiceProvider);

    await service.installAll(endpoint);

    final after = settings().readAsStringSync();
    expect(
      revealHookCommands(after),
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
    expect(
      revealHookCommands(settings().readAsStringSync()),
      isNot(contains(agentHookMarker)),
    );
  });

  group('what each kind of store gets', () {
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

    /// The same store, on a host that is somewhere else entirely — the one
    /// environment this app still has no way to hear from.
    (_StubLocator, ExecutionEnvironment) sshStore() {
      final ssh = sshEnvFixture();
      ExecutionEnvironmentDao(db).upsert(ssh);
      return (
        _StubLocator([
          CliStore(
            environmentId: ssh.id,
            homesByAgentId: {'claudeCode': claudeHome.path},
          ),
        ]),
        ssh,
      );
    }

    Directory spoolDir() =>
        Directory(p.join(claudeHome.path, '$agentHookMarker.spool'));

    test('is installed, and reports by spool rather than by address', () async {
      // The change this group exists for. The app used to write the WSL switch
      // address here; on the owner's machine that address completes the TCP
      // handshake and resets the first data segment — for a bare PowerShell
      // `TcpListener` as readily as for this app — so every hook fired, cost
      // the agent two seconds, and arrived nowhere.
      final (locator, wsl) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);

      final results = await service.installAll(endpoint);

      final claude = results.singleWhere((r) => r.environmentId == wsl.id);
      expect(claude.installed, isTrue);
      expect(claude.skippedBecause, isNull);
      expect(
        revealHookCommands(settings().readAsStringSync()),
        contains(agentHookMarker),
      );
      final endpointText = endpointFile().readAsStringSync();
      expect(endpointText, contains('spool=$agentHookMarker.spool'));
      expect(endpointText, contains('agent=claudeCode'));
      expect(spoolDir().existsSync(), isTrue);
      // No address of any kind, and — the security half of the same fact — no
      // credential at rest inside somebody's distribution. There is no
      // listener here for an impostor to bind, so there is nothing to prove.
      expect(endpointText, isNot(contains('127.0.0.1')));
      expect(endpointText, isNot(contains('url=')));
      expect(endpointText, isNot(contains('token=')));
    });

    test('is what the drainer is told to poll', () async {
      final (locator, wsl) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);

      final report = AgentHookInstallationReport(
        await service.installAll(endpoint),
      );

      expect(report.spoolSources, hasLength(1));
      expect(report.spoolSources.single.environmentId, wsl.id);
      expect(report.spoolSources.single.directory.path, spoolDir().path);
      expect(
        report.spoolSources.single.wslDistribution,
        wsl.wslDistribution,
        reason: 'so the drainer can skip a distribution that is not running',
      );
    });

    test('a local store is not polled: it has a socket', () async {
      final service = containerWith(
        localStore(),
      ).read(agentHookInstallationServiceProvider);

      final report = AgentHookInstallationReport(
        await service.installAll(endpoint),
      );

      expect(report.spoolSources, isEmpty);
      expect(spoolDir().existsSync(), isFalse);
    });

    test(
      'a hook left by an earlier run is removed, not left to fail',
      () async {
        // The owner upgraded, and every prompt in their session printed
        // `curl: (52) Empty reply from server` followed by a failed hook. The
        // entry was written by an older build — a noisier command, and an
        // address that no longer answers — and skipping only ever decided what
        // *not* to write, so nothing in the app could reach in and clear it.
        // An unreachable environment must end this sweep with none of our hooks
        // in it, not with a stale one nobody can remove. SSH is what
        // unreachable means now: another machine, no loopback and no shared
        // filesystem either.
        final (locator, ssh) = sshStore();
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

        final claude = results.singleWhere((r) => r.environmentId == ssh.id);
        expect(claude.installed, isFalse);
        expect(
          claude.skippedBecause,
          contains('left here by an earlier run was removed'),
        );
        final raw = settings().readAsStringSync();
        expect(
          revealHookCommands(raw),
          isNot(contains(agentHookMarker)),
          reason: 'the entry that was failing on every prompt is gone',
        );
        expect(
          raw,
          contains('echo mine'),
          reason: "the user's own hook is not ours to remove",
        );
      },
    );

    test('an unreachable Codex store gets no script either', () async {
      // Codex is the one agent whose callback address lives in a **file we
      // write**, not only in the command. So an environment the endpoint cannot
      // reach has two things to stay clear of, and the sweep has to remove
      // both: an entry an earlier run left is a hook that fires and never
      // arrives, and a script left beside it is a bearer token in somebody's
      // home directory answering to nobody.
      final ssh = sshEnvFixture();
      ExecutionEnvironmentDao(db).upsert(ssh);
      final codexHome = Directory(p.join(claudeHome.path, '.codex'))
        ..createSync(recursive: true);
      final script = File(p.join(codexHome.path, '$agentHookMarker.sh'))
        ..writeAsStringSync('#!/bin/sh\ncurl -s "http://172.18.240.1:9999/"\n');

      final results = await containerWith(
        _StubLocator([
          CliStore(
            environmentId: ssh.id,
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
      final (locator, _) = sshStore();

      await containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider).installAll(endpoint);

      expect(settings().existsSync(), isFalse);
    });

    test('an SSH store is skipped, and says so', () async {
      // Another machine entirely: it shares neither a loopback nor a
      // filesystem with this process, and binding something the LAN could see
      // would put the whole tool surface on the network. The skip has to stay
      // visible — a session reporting `unknown` for a whole run with nothing
      // saying why is the failure this field exists for.
      final (locator, _) = sshStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);

      final results = await service.installAll(endpoint);

      expect(results.single.installed, isFalse);
      expect(
        results.single.skippedBecause,
        contains('no callback address this app binds is reachable'),
      );
      expect(results.single.skippedBecause, contains('state file'));
      expect(settings().existsSync(), isFalse);
    });

    test('uninstall sweeps a WSL store, spool and all', () async {
      // The port is ephemeral and the transport itself has changed under a
      // user before now, so the sweep must match on what we *marked*, not on
      // what we wrote.
      final (locator, _) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);
      await service.installAll(endpoint);
      final entry = settings().readAsStringSync();
      expect(spoolDir().existsSync(), isTrue);
      // A payload that was written but never drained, so the removal has to
      // take a non-empty directory with it.
      File(
        p.join(spoolDir().path, '1234-0.json'),
      ).writeAsStringSync('agent=claudeCode\nevent=Stop\n\n{"session_id":"s"}');

      await service.installAll(
        const AgentHookEndpoint(port: 5555, token: 'tok2'),
      );
      expect(
        settings().readAsStringSync(),
        entry,
        reason: 'a new port rewrites nothing in the config',
      );

      await service.uninstallAll();

      expect(
        revealHookCommands(settings().readAsStringSync()),
        isNot(contains(agentHookMarker)),
      );
      expect(endpointFile().existsSync(), isFalse);
      expect(
        spoolDir().existsSync(),
        isFalse,
        reason: 'uninstall has to leave nothing behind, undrained or not',
      );
      expect(
        File(p.join(claudeHome.path, '$agentHookMarker.sh')).existsSync(),
        isFalse,
      );
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
          AgentHookEndpoint(port: 40000 + launch, token: 'tok$launch'),
        );
      }

      final hooks =
          (jsonDecode(settings().readAsStringSync()) as Map)['hooks'] as Map;
      for (final entry in hooks.entries) {
        final ours = [
          for (final matcher in entry.value as List)
            for (final hook in (matcher as Map)['hooks'] as List)
              if (revealHookCommands(
                (hook as Map)['command'],
              ).contains(agentHookMarker))
                hook['command'],
        ];
        expect(ours, hasLength(1), reason: '${entry.key}');
        // **The headline property.** Ten launches on ten ports and ten tokens
        // wrote one command, and it is the same command every time — so the
        // config was written once and left alone nine times. Every one of those
        // nine writes used to be another chance for the CLI that owns this file
        // to rewrite it from its own start-up copy and take our entry with it.
        expect(ours.single, isNot(contains('4000')));
        expect(ours.single, isNot(contains('tok')));
      }
      expect(settings().readAsStringSync(), contains('mine.sh'));
      // And ten ports later this store still names a directory rather than an
      // address, because its transport does not depend on either.
      expect(
        endpointFile().readAsStringSync(),
        contains('spool=$agentHookMarker.spool'),
      );
      for (var launch = 0; launch < 10; launch++) {
        expect(
          endpointFile().readAsStringSync(),
          isNot(contains('tok$launch')),
        );
      }
    });

    test('the config is written once across ten launches', () async {
      final (locator, _) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);
      await service.installAll(endpoint);
      final afterFirst = settings().readAsStringSync();

      for (var launch = 1; launch < 10; launch++) {
        await service.installAll(
          AgentHookEndpoint(port: 40000 + launch, token: 'tok$launch'),
        );
      }

      expect(
        settings().readAsStringSync(),
        afterFirst,
        reason:
            'byte-for-byte: nine relaunches on nine ports rewrote nobody '
            "else's config file",
      );
    });

    test('retiring the endpoint leaves the entry where it is', () async {
      // The exit path. What dies with the process is the volatile half — how
      // to report, and anything not yet reported — and only that is taken out.
      // The entry is a constant with nothing stale in it, and a config we do
      // not rewrite is a config we cannot lose the race for.
      final (locator, _) = wslStore();
      final service = containerWith(
        locator,
      ).read(agentHookInstallationServiceProvider);
      await service.installAll(endpoint);
      final entry = settings().readAsStringSync();
      expect(endpointFile().existsSync(), isTrue);
      File(
        p.join(spoolDir().path, '99-0.json'),
      ).writeAsStringSync('agent=claudeCode\nevent=Stop\n\n{}');

      final retired = await service.retireEndpoints();

      expect(retired.where((r) => r.installed), isNotEmpty);
      expect(endpointFile().existsSync(), isFalse);
      expect(
        spoolDir().existsSync(),
        isFalse,
        reason:
            'the payloads in it belong to a launch, and there is no launch '
            'any more; with the directory gone the script costs the agent one '
            'test and exits zero',
      );
      expect(settings().readAsStringSync(), entry);
      expect(
        File(p.join(claudeHome.path, '$agentHookMarker.sh')).existsSync(),
        isTrue,
        reason: 'the script is a constant too, and stays',
      );
    });
  });

  test('no token reaches a log line', () async {
    // The sweep logs an agent id, an environment id and a reason, and it has to
    // keep doing exactly that. The token never may be in one, and it is the
    // only thing this feature holds that a diagnostic could not honestly print.
    //
    // The failing branch is the one exercised on purpose: a config that cannot
    // be parsed is the path that builds a message out of what went wrong, so
    // it is where a future `'$endpoint'` would land first.
    final records = <LogRecord>[];
    AppLogger.initialize(level: Level.ALL, onRecord: records.add);
    addTearDown(AppLogger.initialize);
    const secret = AgentHookEndpoint(port: 4242, token: 'S3CRET-hook-token');
    final wsl = wslEnv();
    ExecutionEnvironmentDao(db).upsert(wsl);
    settings().writeAsStringSync('{ not json');
    final service = containerWith(
      _StubLocator([
        CliStore(
          environmentId: wsl.id,
          homesByAgentId: {'claudeCode': claudeHome.path},
        ),
      ]),
    ).read(agentHookInstallationServiceProvider);

    await service.installAll(secret);
    await service.retireEndpoints();
    await service.uninstallAll();

    expect(records, isNotEmpty, reason: 'otherwise this proves nothing');
    expect(
      records.map((r) => r.message),
      contains(contains('claudeCode')),
      reason: 'what failed and where is the part that has to be said out loud',
    );
    for (final record in records) {
      expect(
        '${record.message} ${record.error}',
        isNot(contains(secret.token)),
        reason: record.message,
      );
    }
  });

  test('one unparseable config does not stop or corrupt the others', () async {
    // Two stores, and the first cannot be read. The walk has to finish, the
    // reachable store has to be written, and the broken file has to be left
    // exactly as it was — it is somebody's real settings.json.
    final broken = Directory.systemTemp.createTempSync(
      'karmashala_hooksvc_bad_',
    );
    addTearDown(() => removeTempDirectory(broken));
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

    final results = await service.installAll(endpoint);

    expect(brokenConfig.readAsStringSync(), '{ not json');
    expect(
      broken.listSync().map((e) => p.basename(e.path)).toList(),
      ['settings.json'],
      reason:
          'nothing written beside a config we could not read — not a staged '
          'temporary, and not a bearer token in an endpoint file for a store '
          'whose settings.json we never opened',
    );
    final failed = results.singleWhere((r) => r.environmentId == wsl.id);
    expect(failed.installed, isFalse);
    expect(failed.skippedBecause, contains('FormatException'));
    final good = results.singleWhere(
      (r) => r.environmentId == localEnvironmentId(),
    );
    expect(good.installed, isTrue);
    expect(
      revealHookCommands(settings().readAsStringSync()),
      contains(agentHookMarker),
    );
  });
}
