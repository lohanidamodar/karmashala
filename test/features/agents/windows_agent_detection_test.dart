import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/agents/data/agent_discovery_service.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

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
  AgentDescriptor(
    id: AgentIds.claudeCode,
    displayName: 'Claude Code',
    binaries: AgentBinaries(
      windows: ['claude'],
      posix: ['claude'],
      windowsInstallPaths: [r'%USERPROFILE%\.local\bin\claude.exe'],
    ),
  ),
]);

void main() {
  group('Windows discovery — on PATH', () {
    test('an agent on the Windows PATH is discovered with its version', () async {
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
    });
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
        runner.requests.where((r) => r.executable.endsWith('claude.exe')).length,
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
        runner.requests.any(
          (r) => r.executable.contains(r'.local\bin'),
        ),
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

    test('every declared location is an absolute file path, not a directory', () {
      for (final descriptor in AgentRegistry.builtIn.descriptors) {
        for (final template in descriptor.binaries.windowsInstallPaths) {
          expect(
            template.endsWith('.exe'),
            isTrue,
            reason: '$template must name one executable — discovery probes '
                'exactly these files and never walks the disk',
          );
        }
      }
    });
  });
}
