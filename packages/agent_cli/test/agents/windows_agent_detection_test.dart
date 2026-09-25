import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/agents/data/agent_discovery_service.dart';
import 'package:agent_cli/src/agents/domain/agent_descriptor.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';
import 'package:agent_cli/src/agents/adapter/data_only_agent_adapter.dart';
import '../support/fake_path_probe.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';

/// `where` prints nothing and exits 1 when a name is not on PATH. That is a
/// *result*, not a failure — the same shape the owner's machine produced for
/// every agent while `codex.exe` sat on the PATH of a freshly started process.
const _notOnPath = CommandResult(
  exitCode: 1,
  stdout: '',
  stderr: 'INFO: Could not find files for the given pattern(s).',
);

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// A registry of one agent that declares a Windows install location.
const _declaring = AgentRegistry([
  DataOnlyAgentAdapter(
    AgentDescriptor(
      id: AgentIds.claudeCode,
      displayName: 'Claude Code',
      binaries: AgentBinaries(
        windows: ['claude'],
        posix: ['claude'],
        windowsInstallPaths: [r'%USERPROFILE%\.local\bin\claude.exe'],
      ),
    ),
  ),
]);

void main() {
  group('Windows discovery — on PATH', () {
    test(
      'an agent on the Windows PATH is discovered with its version',
      () async {
        final runner = FakeCommandRunner(
          responder: (req) {
            if (req.executable == 'where') {
              return req.arguments.first == 'codex'
                  ? _ok(
                      r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin'
                      '\\codex.exe\r\n',
                    )
                  : _notOnPath;
            }
            return _ok('codex-cli 0.145.0');
          },
        );

        final found = await AgentDiscoveryService(
          runner: runner,
          environment: windowsEnv(),
          ids: SequentialIdGenerator(),
          clock: FixedClock(testTime),
          // No variables, so no declared install path expands: this test is
          // about the PATH lookup alone, on any machine.
          hostEnvironment: const {},
        ).discover();

        expect(found.map((i) => i.agentId), [AgentIds.codex]);
        expect(
          found.single.executable.path,
          r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe',
        );
        expect(found.single.version, '0.145.0');
      },
    );
  });

  group('Windows discovery — declared install locations', () {
    test('finds an agent that is installed but not on PATH', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable == 'where') return _notOnPath;
          expect(req.executable, r'C:\Users\d\.local\bin\claude.exe');
          return _ok('2.1.252 (Claude Code)');
        },
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      expect(found.map((i) => i.agentId), [AgentIds.claudeCode]);
      expect(found.single.executable.path, r'C:\Users\d\.local\bin\claude.exe');
      // The existence check *is* the version probe, so it must not be re-run.
      expect(found.single.version, '2.1.252');
      expect(
        runner.requests
            .where((r) => r.executable.endsWith('claude.exe'))
            .length,
        1,
      );
    });

    test('a declared location that holds nothing yields no agent', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable == 'where') return _notOnPath;
          // dart:io raises ProcessException for a missing file; the Windows
          // runner turns that into CommandException.
          throw CommandException('The system cannot find the file specified.');
        },
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      expect(found, isEmpty);
    });

    test('an unset variable is skipped rather than probed literally', () async {
      final runner = FakeCommandRunner(
        responder: (req) => req.executable == 'where' ? _notOnPath : _ok('x'),
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        hostEnvironment: const {},
      ).discover();

      expect(found, isEmpty);
      expect(runner.requests.map((r) => r.executable), everyElement('where'));
    });

    test('PATH wins: a declared location is only a fallback', () async {
      final runner = FakeCommandRunner(
        responder: (req) => req.executable == 'where'
            ? _ok('C:\\tools\\claude.exe\r\n')
            : _ok('2.1.252'),
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      expect(found.single.executable.path, r'C:\tools\claude.exe');
      expect(
        runner.requests.any((r) => r.executable.contains(r'.local\bin')),
        isFalse,
      );
    });

    test('POSIX environments never probe Windows install locations', () async {
      final runner = FakeCommandRunner(
        responder: (req) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: ''),
      );

      await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      expect(runner.requests.map((r) => r.executable), everyElement('bash'));
    });
  });

  group('Windows discovery — a declared location behind a junction', () {
    // Measured on the owner's machine 2026-09-07: Codex self-updated to a
    // versioned standalone layout and turned the stable path its own installer
    // advertises into a chain of junctions Windows refuses to traverse. `where
    // codex` answers "Could not find files", `File.existsSync` on the leaf
    // answers a flat false, and `Process.run` raises — so before the resolver
    // there was no route by which discovery could see a working CLI at all.
    const declared = r'C:\Users\d\.local\bin\claude.exe';
    const declaredDir = r'C:\Users\d\.local\bin';
    const release = r'C:\Users\d\.store\releases\2.1.252';
    const real = r'C:\Users\d\.store\releases\2.1.252\claude.exe';

    FakePathProbe behindAJunction() =>
        FakePathProbe(files: const {real}, links: const {declaredDir: release});

    test('is found at the path the junction actually leads to', () async {
      final runner = FakeCommandRunner(
        responder: (req) =>
            req.executable == 'where' ? _notOnPath : _ok('2.1.252'),
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        pathProbe: behindAJunction(),
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      // The resolved path is what gets stored, because it is the only one that
      // can be spawned — and the only one that was spawned.
      expect(found.single.executable.path, real);
      expect(found.single.version, '2.1.252');
      expect(
        runner.requests
            .where((r) => r.executable != 'where')
            .map((r) => r.executable),
        [real],
      );
    });

    test('a declared location the walk proves empty is not spawned', () async {
      // The route completed and there is nothing at the end of it. Spawning to
      // confirm would cost a process per launch per uninstalled agent.
      final runner = FakeCommandRunner(
        responder: (req) => req.executable == 'where' ? _notOnPath : _ok('x'),
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        pathProbe: FakePathProbe(),
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      expect(found, isEmpty);
      expect(runner.requests.map((r) => r.executable), everyElement('where'));
    });

    test('a PATH hit that cannot be traversed is stored resolved', () async {
      final runner = FakeCommandRunner(
        responder: (req) =>
            req.executable == 'where' ? _ok('$declared\r\n') : _ok('2.1.252'),
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        pathProbe: behindAJunction(),
        hostEnvironment: const {},
      ).discover();

      expect(found.single.executable.path, real);
    });

    test('a working PATH hit keeps the spelling its installer chose', () async {
      // Resolving a healthy install would trade a stable path for whatever it
      // points at today, which rots on the next update for no benefit.
      final runner = FakeCommandRunner(
        responder: (req) => req.executable == 'where'
            ? _ok(r'C:\tools\claude.exe')
            : _ok('2.1.252'),
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        pathProbe: FakePathProbe(
          files: const {r'C:\tools\claude.exe'},
          links: const {r'C:\tools': r'C:\elsewhere'},
        ),
        hostEnvironment: const {},
      ).discover();

      expect(found.single.executable.path, r'C:\tools\claude.exe');
    });

    test('no probe at all leaves discovery exactly as it was', () async {
      // The filesystem read is additive: a caller with none to offer loses the
      // repair and nothing else.
      final runner = FakeCommandRunner(
        responder: (req) =>
            req.executable == 'where' ? _notOnPath : _ok('2.1.252'),
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      expect(found.single.executable.path, declared);
    });

    test('a POSIX environment reads no filesystem even with a probe', () async {
      // The resolver is a Windows-native concern: a WSL or SSH path belongs to
      // a disk this process cannot stat, and reading ours would be evidence
      // about the wrong machine.
      final probe = FakePathProbe();
      final runner = FakeCommandRunner(
        responder: (req) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: ''),
      );

      await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _declaring,
        pathProbe: probe,
        hostEnvironment: const {'USERPROFILE': r'C:\Users\d'},
      ).discover();

      expect(probe.queries, isEmpty);
    });
  });

  group('expandWindowsPath', () {
    test('substitutes %VAR% from the host environment', () {
      expect(
        expandWindowsPath(r'%USERPROFILE%\.local\bin\claude.exe', const {
          'USERPROFILE': r'C:\Users\d',
        }),
        r'C:\Users\d\.local\bin\claude.exe',
      );
    });

    test('is case-insensitive, as Windows variables are', () {
      expect(
        expandWindowsPath(r'%localappdata%\x.exe', const {
          'LOCALAPPDATA': r'C:\Users\d\AppData\Local',
        }),
        r'C:\Users\d\AppData\Local\x.exe',
      );
    });

    test('returns null when a variable is unset', () {
      expect(expandWindowsPath(r'%NOPE%\x.exe', const {}), isNull);
    });

    test('leaves a template with no variables alone', () {
      expect(expandWindowsPath(r'C:\x.exe', const {}), r'C:\x.exe');
    });
  });

  group('built-in descriptors', () {
    test('Claude Code declares its native Windows installer target', () {
      final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
      expect(
        claude.binaries.windowsInstallPaths,
        contains(r'%USERPROFILE%\.local\bin\claude.exe'),
      );
    });

    test('Codex declares its Windows installer target', () {
      final codex = AgentRegistry.builtIn.byId(AgentIds.codex)!;
      expect(
        codex.binaries.windowsInstallPaths,
        contains(r'%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe'),
      );
    });

    test(
      'every declared location is an absolute file path, not a directory',
      () {
        for (final descriptor in AgentRegistry.builtIn.descriptors) {
          for (final template in descriptor.binaries.windowsInstallPaths) {
            expect(
              template.endsWith('.exe'),
              isTrue,
              reason:
                  '$template must name one executable — discovery probes '
                  'exactly these files and never walks the disk',
            );
          }
        }
      },
    );
  });
}
