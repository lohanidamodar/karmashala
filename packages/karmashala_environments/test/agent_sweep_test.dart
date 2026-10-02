import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/sweep.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/fixtures.dart';
import 'support/sweep_world.dart';

/// **The sweep's rules**: what a re-detect finds, adds, removes, keeps and
/// reports; that every environment is asked at once; and which pairs the
/// probe log says were searched. The environments and their replies are
/// described, so nothing here spawns a real CLI.
void main() {
  group('a sweep of every environment', () {
    // Every request a sweep made, as `executable + arguments`, for the count
    // that concurrency must not change.
    late List<String> calls;
    late SweepWorld world;

    // Both environments report only Claude installed.
    FakeCommandRunner claudeOnlyRunner() => FakeCommandRunner(
      responder: (req) {
        calls.add('${req.executable} ${req.arguments.join(' ')}');
        // Windows probes with `where <name>`; WSL probes through a login shell
        // as `bash -lc 'command -v <name>'`.
        final isWindowsLocate = req.executable == 'where';
        final isWslLocate =
            req.executable == 'bash' && req.arguments.first == '-lc';
        // A reachable environment answers the liveness probe a reconciling
        // scan runs before it will delete anything.
        if (isWslLocate && req.arguments.last == 'exit 0') {
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (isWindowsLocate || isWslLocate) {
          final target = isWslLocate
              ? req.arguments.last.split(' ').last
              : req.arguments.first;
          return target == 'claude'
              ? const CommandResult(
                  exitCode: 0,
                  stdout: '/usr/bin/claude\n',
                  stderr: '',
                )
              : const CommandResult(exitCode: 1, stdout: '', stderr: '');
        }
        return const CommandResult(exitCode: 0, stdout: '2.0.0', stderr: '');
      },
    );

    setUp(() {
      calls = [];
      world = SweepWorld([windowsEnv(), wslEnv()]);
    });

    test('discovers the same agent independently per environment', () async {
      final runner = claudeOnlyRunner();
      final report = await world.sweep(runnerFor: (_) => runner).sweep();

      expect(report.foundCount, 2);
      final installations = world.installations.getAll();
      expect(installations.map((i) => i.environmentId).toSet(), {
        'windows',
        'wsl:Ubuntu',
      });
      expect(
        installations.every((i) => i.agentId == AgentIds.claudeCode),
        isTrue,
      );
      expect(installations.every((i) => i.version == '2.0.0'), isTrue);
    });

    test(
      'every environment is asked at once, and asked exactly as often',
      () async {
        // The environments are independent — a WSL distribution and a Mac
        // over SSH have nothing to say to each other — so awaiting them in
        // turn costs the sum rather than the longest.
        //
        // Two claims, both counted rather than timed: the second environment
        // is reached while the first is still held, and the number of calls is
        // exactly what a sequential sweep made.
        final plain = claudeOnlyRunner();
        await world.sweep(runnerFor: (_) => plain).sweep();
        final sequential = [...calls];
        calls.clear();

        final gate = Completer<void>();
        final held = _HoldingRunner(
          inner: claudeOnlyRunner(),
          hold: (req) => req.executable == 'where' ? gate.future : null,
        );
        final second = SweepWorld([windowsEnv(), wslEnv()]);

        final sweep = second.sweep(runnerFor: (_) => held).sweep();
        await pumpEventQueue();
        // Every Windows call is held, so anything from WSL here happened while
        // the Windows environment was still waiting. Sequentially this list
        // would hold nothing but `where`.
        expect(
          calls.where((c) => c.startsWith('bash')),
          isNotEmpty,
          reason: 'WSL was reached while Windows was still held',
        );
        gate.complete();

        final report = await sweep;
        expect(report.foundCount, 2);
        // Same calls, in some order: concurrency changed when they happen, not
        // how many there are or what they ask.
        expect(calls.length, sequential.length);
        expect(calls.toSet(), sequential.toSet());
      },
    );

    test('re-running discovery does not duplicate installations', () async {
      final runner = claudeOnlyRunner();
      final sweep = world.sweep(runnerFor: (_) => runner);
      await sweep.sweep();
      await sweep.sweep();
      expect(world.installations.getAll(), hasLength(2));
    });

    test('an environment with no runner is unreachable, and says why', () async {
      // A `Future.wait` fails on its first error and loses the rest, so one
      // environment that cannot even be asked must not cost the others theirs.
      final runner = claudeOnlyRunner();
      final report = await world
          .sweep(
            runnerFor: (environment) => environment.id == 'wsl:Ubuntu'
                ? throw StateError('no distribution recorded')
                : runner,
          )
          .sweep();

      final wsl = report.environments.firstWhere(
        (e) => e.environmentId == 'wsl:Ubuntu',
      );
      expect(wsl.reachable, isFalse);
      expect(wsl.error, contains('no distribution recorded'));
      expect(report.foundCount, 1, reason: 'Windows still answered');
      expect(
        world.probeLog.hasProbed(AgentIds.claudeCode, 'wsl:Ubuntu'),
        isFalse,
        reason: 'a probe not performed is not recorded as performed',
      );
      expect(world.probeLog.hasProbed(AgentIds.claudeCode, 'windows'), isTrue);
    });

    test('a refused write is reported, not swallowed', () async {
      final runner = claudeOnlyRunner();
      world.installations.refuseReconcile = StateError('the server said no');

      final report = await world.sweep(runnerFor: (_) => runner).sweep();

      expect(report.environments.every((e) => !e.reachable), isTrue);
      expect(
        report.environments.first.error,
        allOf(contains('It was not recorded'), contains('the server said no')),
      );
      expect(world.installations.getAll(), isEmpty);
      expect(
        world.probeLogJson,
        isNull,
        reason: 'not recorded, so not probed: the next sweep asks again',
      );
    });

    test('only narrows to the environments and agents it names', () async {
      final runner = claudeOnlyRunner();
      final report = await world
          .sweep(runnerFor: (_) => runner)
          .sweep(
            only: {
              'windows': {AgentIds.claudeCode},
              'wsl:Ubuntu': const {},
            },
          );

      expect(report.environments.map((e) => e.environmentId), ['windows']);
      expect(calls.where((c) => c.startsWith('bash')), isEmpty);
      expect(calls.where((c) => c.startsWith('where')).toList(), [
        'where claude',
      ]);
      expect(world.probeLog.entries().keys, [AgentIds.claudeCode]);
    });
  });

  // A sweep of the local host alone, answering `where <name>` however the case
  // at hand needs it. The local host has no reachability probe — it is the
  // machine running the code — so whatever this says is taken as evidence.
  group('an installation that ran sessions', () {
    late SweepWorld world;

    AgentSweep sweepFinding(Map<String, String> onPath) {
      world = SweepWorld([windowsEnv()]);
      world.installations
        ..insert(agentInstallation(id: 'old', path: r'C:\old\claude.exe'))
        // A session ran on it.
        ..referenced.add('old');
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable != 'where') {
            return const CommandResult(
              exitCode: 0,
              stdout: '3.0.0',
              stderr: '',
            );
          }
          final hit = onPath[req.arguments.first];
          return hit == null
              ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
              : CommandResult(exitCode: 0, stdout: hit, stderr: '');
        },
      );
      return world.sweep(runnerFor: (_) => runner);
    }

    test(
      'survives a sweep that finds nothing, rather than blinding the app',
      () async {
        // `sessions.agent_installation_id` is ON DELETE RESTRICT, so tidying
        // away the row for an agent no longer on PATH once raised out of the
        // middle of the sweep, and the whole run died with it.
        final report = await sweepFinding(const {}).sweep();

        expect(report.environments.single.reachable, isTrue);
        expect(report.retainedCount, 1);
        expect(report.removedCount, 0);
        // Kept, so the session it ran can still say what ran it.
        expect(world.installations.getAll().single.id, 'old');
      },
    );

    test(
      'follows its agent to a new path, keeping its id and its sessions',
      () async {
        final report = await sweepFinding(const {
          'claude': 'C:\\new\\claude.exe\r\n',
        }).sweep();

        // One row, at the new path: the old one is gone rather than kept
        // alongside it as a second, dead Claude Code.
        final installations = world.installations.getAll();
        expect(installations.single.executable.path, r'C:\new\claude.exe');
        // **Moved, not replaced**: settings pin an installation id, and every
        // session row points at it.
        expect(installations.single.id, 'old');
        expect(report.movedCount, 1);
        expect(report.removedCount, 0);
        expect(report.retainedCount, 0);
      },
    );
  });

  group('re-detect', () {
    /// Two agents, neither declaring a Windows install location — these cases
    /// are about what re-detection does with what it finds, not where it
    /// looks.
    const registry = AgentRegistry([
      DataOnlyAgentAdapter(
        AgentDescriptor(
          id: AgentIds.claudeCode,
          displayName: 'Claude Code',
          binaries: AgentBinaries(windows: ['claude'], posix: ['claude']),
        ),
      ),
      DataOnlyAgentAdapter(
        AgentDescriptor(
          id: AgentIds.codex,
          displayName: 'Codex CLI',
          binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
        ),
      ),
    ]);

    late SweepWorld world;
    late AgentSweep sweep;

    /// Names currently "installed" on the fake host, mapped to their version.
    late Map<String, String> installed;
    late bool reachable;

    FakeCommandRunner hostRunner() => FakeCommandRunner(
      responder: (req) {
        if (req.executable == 'bash') {
          final script = req.arguments.last;
          if (!reachable) {
            return const CommandResult(
              exitCode: 1,
              stdout: '',
              stderr: 'The distribution is not running.',
            );
          }
          if (script == 'exit 0') {
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          }
          final name = script.split(' ').last;
          return installed.containsKey(name)
              ? CommandResult(
                  exitCode: 0,
                  stdout: '/usr/bin/$name\n',
                  stderr: '',
                )
              : const CommandResult(exitCode: 1, stdout: '', stderr: '');
        }
        if (req.executable == 'where') {
          final name = req.arguments.first;
          return installed.containsKey(name)
              ? CommandResult(
                  exitCode: 0,
                  stdout: 'C:\\bin\\$name.exe\r\n',
                  stderr: '',
                )
              : const CommandResult(exitCode: 1, stdout: '', stderr: '');
        }
        // A version probe of a located executable.
        final name = req.executable
            .split(RegExp(r'[\\/]'))
            .last
            .split('.')
            .first;
        return CommandResult(
          exitCode: 0,
          stdout: installed[name] ?? '',
          stderr: '',
        );
      },
    );

    setUp(() {
      installed = {'claude': '2.1.0'};
      reachable = true;
      world = SweepWorld([windowsEnv()]);
      final runner = hostRunner();
      sweep = world.sweep(runnerFor: (_) => runner, registry: registry);
    });

    test('picks up an agent installed since the last scan', () async {
      await sweep.sweep();
      expect(world.installations.getAll(), hasLength(1));

      installed['codex'] = '0.151.0';
      final report = await sweep.sweep();

      expect(report.addedCount, 1);
      expect(report.foundCount, 2);
      expect(world.installations.getAll().map((i) => i.agentId).toSet(), {
        AgentIds.claudeCode,
        AgentIds.codex,
      });
    });

    test('drops an agent that has been removed', () async {
      installed['codex'] = '0.151.0';
      await sweep.sweep();
      expect(world.installations.getAll(), hasLength(2));

      installed.remove('codex');
      final report = await sweep.sweep();

      expect(report.removedCount, 1);
      expect(report.foundCount, 1);
      expect(world.installations.getAll().map((i) => i.agentId), [
        AgentIds.claudeCode,
      ]);
    });

    test('drops a row whose agent the registry no longer knows', () async {
      // An ACP agent a person added and then removed: the registry forgets
      // its kind while its row — and its command — are still there.
      final row = AcpAgentRow(
        id: 'r1',
        name: 'Mine',
        command: 'mine',
        createdAt: testTime,
      );
      var current = AgentRegistry([...registry.adapters, acpAgentAdapter(row)]);
      final runner = hostRunner();
      sweep = world.sweep(
        runnerFor: (_) => runner,
        registry: registry,
        registryNow: () => current,
      );
      installed['mine'] = '1.0.0';
      await sweep.sweep();
      expect(
        world.installations.getAll().map((i) => i.agentId),
        containsAll([AgentIds.claudeCode, row.agentId]),
      );

      current = registry;
      final report = await sweep.sweep();

      expect(report.removedCount, 1);
      expect(world.installations.getAll().map((i) => i.agentId), [
        AgentIds.claudeCode,
      ]);
    });

    test('records a changed version in place', () async {
      await sweep.sweep();
      final before = world.installations.getAll().single;
      expect(before.version, '2.1.0');

      installed['claude'] = '2.1.252';
      final report = await sweep.sweep();

      expect(report.updatedCount, 1);
      final after = world.installations.getAll().single;
      expect(after.version, '2.1.252');
      expect(
        after.id,
        before.id,
        reason: 'the same installation, not a new row',
      );
      expect(report.addedCount, 0);
      expect(report.removedCount, 0);
    });

    test('the report names what was NOT found', () async {
      final report = await sweep.sweep();

      expect(report.foundCount, 1);
      final windows = report.environments.single;
      expect(windows.missing, ['Codex CLI']);
      expect(report.summary, contains('Codex CLI'));
      expect(report.summary, contains('1 agent'));
    });

    test(
      'a scan that finds nothing says so rather than claiming success',
      () async {
        installed.clear();
        final report = await sweep.sweep();

        expect(report.foundCount, 0);
        expect(report.summary.toLowerCase(), contains('no agents'));
      },
    );

    test('an unreachable environment keeps its installations', () async {
      world.addEnvironment(wslEnv());
      installed['codex'] = '0.151.0';
      await sweep.sweep();
      int wslRows() =>
          world.installations.getByEnvironment('wsl:Ubuntu').length;
      expect(wslRows(), 2);

      // The distro is stopped. Its agents did not vanish; they simply cannot
      // be seen, and deleting them would be a lie dressed as a scan result.
      reachable = false;
      final report = await sweep.sweep();

      expect(wslRows(), 2);
      final wsl = report.environments.firstWhere(
        (e) => e.environmentId == 'wsl:Ubuntu',
      );
      expect(wsl.reachable, isFalse);
      expect(wsl.error, 'The distribution is not running.');
      expect(report.removedCount, 0);
      expect(report.summary.toLowerCase(), contains('could not reach'));
    });

    test('a sweep ignores the probe log, so a stale miss is retried', () async {
      // The first scan recorded "codex: searched, windows", and
      // `discoverUnprobed` then skips Windows on every start — so an agent
      // installed later is found only by the sweep, which is the recovery path.
      await sweep.sweep();
      installed['codex'] = '0.151.0';
      expect(await sweep.discoverUnprobed(), isEmpty);

      final report = await sweep.sweep();
      expect(report.addedCount, 1);
    });
  });

  group('one environment\'s scan', () {
    late SweepWorld world;

    FakeCommandRunner onPath(Set<String> names) => FakeCommandRunner(
      responder: (req) {
        if (req.executable == 'where') {
          final name = req.arguments.first;
          return names.contains(name)
              ? CommandResult(
                  exitCode: 0,
                  stdout: 'C:\\bin\\$name.exe\r\n',
                  stderr: '',
                )
              : const CommandResult(exitCode: 1, stdout: '', stderr: '');
        }
        return const CommandResult(exitCode: 0, stdout: '1.2.3', stderr: '');
      },
    );

    setUp(() => world = SweepWorld([windowsEnv()]));

    test('adds what answered and judges no row it did not find', () async {
      world.installations.insert(
        agentInstallation(
          id: 'gone',
          agentId: AgentIds.codex,
          path: r'C:\gone\codex.exe',
        ),
      );
      final runner = onPath({'claude'});

      final report = await world
          .sweep(runnerFor: (_) => runner)
          .scan(windowsEnv());

      expect(report.addedCount, 1);
      expect(report.removedCount, 0);
      expect(
        world.installations.getById('gone'),
        isNotNull,
        reason: 'a scan is add-only',
      );
      expect(
        world.probeLogJson,
        isNull,
        reason: 'a scan is not the sweep and records no search',
      );
    });

    test('an environment that does not answer is reported so', () async {
      final report = await world
          .sweep(runnerFor: (_) => throw StateError('no runner'))
          .scan(windowsEnv());

      expect(report.environments.single.reachable, isFalse);
      expect(report.environments.single.error, contains('no runner'));
    });
  });

  group('the agents nobody has searched for', () {
    late SweepWorld world;
    late FakeCommandRunner runner;
    late AgentSweep sweep;

    /// The owner's machine, in miniature: `agy` is on the login PATH inside
    /// WSL and nowhere on Windows, and `claude`/`codex` are found by neither
    /// call because nothing should ever ask.
    FakeCommandRunner agyInWslRunner() => FakeCommandRunner(
      responder: (req) {
        final isWindowsLocate = req.executable == 'where';
        final isPosixLocate =
            req.executable == 'bash' && req.arguments.first == '-lc';
        if (isPosixLocate && req.arguments.last == 'exit 0') {
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (isWindowsLocate || isPosixLocate) {
          final target = isPosixLocate
              ? req.arguments.last.split(' ').last
              : req.arguments.first;
          return target == 'agy' && isPosixLocate
              ? const CommandResult(
                  exitCode: 0,
                  stdout: '/home/dlohani/.local/bin/agy\n',
                  stderr: '',
                )
              : const CommandResult(exitCode: 1, stdout: '', stderr: '');
        }
        return const CommandResult(exitCode: 0, stdout: '1.1.22', stderr: '');
      },
    );

    /// The four rows the owner's workspace actually held: two agents, two
    /// environments, all stamped long before `antigravity` joined the
    /// registry.
    void seedPreAntigravityInstallations() {
      var n = 0;
      for (final agentId in [AgentIds.claudeCode, AgentIds.codex]) {
        for (final environmentId in ['windows', 'wsl:archlinux']) {
          world.installations.insert(
            agentInstallation(
              id: 'a${n++}',
              agentId: agentId,
              environmentId: environmentId,
              path: '/home/dlohani/.local/bin/$agentId',
            ),
          );
        }
      }
    }

    /// Every executable name a locate request asked about, in order.
    List<String> located() => [
      for (final req in runner.requests)
        if (req.executable == 'where')
          req.arguments.first
        else if (req.executable == 'bash' && req.arguments.first == '-lc')
          req.arguments.last.split(' ').last,
    ];

    setUp(() {
      runner = agyInWslRunner();
      world = SweepWorld([
        windowsEnv(),
        wslEnv(id: 'wsl:archlinux', distro: 'archlinux'),
      ]);
      // The three terminal agents only: these cases count what a start
      // probes for, and the ACP agents' own discovery (npx fallback included)
      // is agent_cli's to test.
      sweep = world.sweep(
        runnerFor: (environment) => environment.kind == EnvironmentKind.ssh
            ? throw StateError('a start does not dial an SSH host')
            : runner,
        registry: AgentRegistry([
          for (final adapter in builtInAgentAdapters)
            if (adapter.acp == null) adapter,
        ]),
      );
    });

    test(
      'an agent added by an upgrade is found without a manual rescan',
      () async {
        seedPreAntigravityInstallations();

        final found = await sweep.discoverUnprobed();

        expect(found.map((i) => i.agentId), [AgentIds.antigravity]);
        expect(found.single.environmentId, 'wsl:archlinux');
        expect(found.single.executable.path, '/home/dlohani/.local/bin/agy');
        expect(found.single.version, '1.1.22');
        expect(
          world.installations.getAll(),
          hasLength(5),
          reason: 'the four seeded rows plus the one nobody had looked for',
        );
      },
    );

    test('an agent already installed here is never probed', () async {
      seedPreAntigravityInstallations();

      await sweep.discoverUnprobed();

      // An installation row is itself proof somebody looked. Re-probing it
      // would spawn a process per agent per environment on every start.
      expect(located().toSet(), {'agy'});
      expect(
        located(),
        hasLength(2),
        reason: 'once per unprobed agent per environment, no more',
      );
    });

    test('an agent looked for and absent is not looked for again', () async {
      seedPreAntigravityInstallations();
      await sweep.discoverUnprobed();
      runner.requests.clear();

      final second = await sweep.discoverUnprobed();

      expect(second, isEmpty);
      expect(
        runner.requests,
        isEmpty,
        reason: 'a miss is recorded, so the next start spawns nothing at all',
      );
      expect(world.probeLog.hasProbed(AgentIds.antigravity, 'windows'), isTrue);
    });

    test(
      'a remote host is not dialled, and is not recorded as searched',
      () async {
        world.addEnvironment(sshEnvFixture());
        seedPreAntigravityInstallations();

        await sweep.discoverUnprobed();

        // A start must not reach out to every saved machine. The pair stays
        // unrecorded because it was skipped, not searched — "Discover agents" on
        // that environment still has work to do.
        expect(
          world.probeLog.hasProbed(AgentIds.antigravity, 'ssh:h1'),
          isFalse,
        );
      },
    );

    test(
      'a workspace that has never discovered anything probes everything',
      () async {
        final found = await sweep.discoverUnprobed();

        expect(located().toSet(), {'claude', 'codex', 'agy'});
        expect(found.map((i) => i.agentId), [AgentIds.antigravity]);
      },
    );

    test('a find the server refuses to record is asked about again', () async {
      world.installations.refuseReconcile = StateError('the server said no');

      final found = await sweep.discoverUnprobed();

      expect(found, isEmpty);
      expect(
        world.probeLog.hasProbed(AgentIds.antigravity, 'wsl:archlinux'),
        isFalse,
        reason: 'not recorded, so not probed either',
      );
      // Windows found nothing, so it had nothing to record and was searched.
      expect(world.probeLog.hasProbed(AgentIds.antigravity, 'windows'), isTrue);
    });
  });
}

/// A runner that records what it was asked and can hold some of its answers.
///
/// Holding is how "these two ran at once" is *counted* rather than timed: with
/// every call into one environment held, anything recorded from the other one
/// happened while the first was still waiting — and a sequential sweep would
/// deadlock instead of passing.
class _HoldingRunner extends FakeCommandRunner {
  _HoldingRunner({required this.inner, required this.hold});

  final FakeCommandRunner inner;
  final Future<void>? Function(CommandRequest request) hold;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final wait = hold(request);
    if (wait != null) await wait;
    return inner.run(request);
  }
}
