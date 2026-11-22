import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:test/test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
const _notFound = CommandResult(exitCode: 1, stdout: '', stderr: '');

/// Antigravity ACP prefers the native `agy acp` subcommand on `agy` 1.5.0+,
/// falls back to standalone `agy_acp_server` where `agy` is older or absent,
/// exposes both mode vocabularies, and wires usage.
void main() {
  group('agy acp discovery', () {
    test('prefers `agy acp` when `agy` is 1.5.0 or newer', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          final script = req.arguments.length > 1 ? req.arguments.last : '';
          if (script == 'command -v agy') return _ok('/home/u/.local/bin/agy\n');
          if (req.executable == '/home/u/.local/bin/agy' &&
              req.arguments.contains('--version')) {
            return _ok('agy version 1.5.13\n');
          }
          return _notFound;
        },
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();

      final chat = found.singleWhere(
        (i) => i.agentId == AgentIds.antigravityAcp,
      );
      expect(chat.executable.path, '/home/u/.local/bin/agy');
      expect(chat.leadingArguments, ['acp']);
      expect(chat.version, '1.5.13');
    });

    test('falls back to standalone agy_acp_server when `agy` is below 1.5.0', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          final script = req.arguments.length > 1 ? req.arguments.last : '';
          if (script == 'command -v agy') return _ok('/home/u/.local/bin/agy\n');
          if (script == 'command -v agy_acp_server.par') {
            return _ok('/opt/acp/agy_acp_server.par\n');
          }
          if (req.executable == '/home/u/.local/bin/agy' &&
              req.arguments.contains('--version')) {
            return _ok('agy version 1.4.2\n');
          }
          return _notFound;
        },
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();

      final chat = found.singleWhere(
        (i) => i.agentId == AgentIds.antigravityAcp,
      );
      expect(chat.executable.path, '/opt/acp/agy_acp_server.par');
      expect(chat.leadingArguments, isEmpty);
    });

    test('discovers standalone agy_acp_server.exe on Windows when `agy` is absent', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable == 'where' &&
              req.arguments.single == 'agy_acp_server.exe') {
            return _ok('C:\\tools\\agy_acp_server.exe\r\n');
          }
          return _notFound;
        },
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();

      final chat = found.singleWhere(
        (i) => i.agentId == AgentIds.antigravityAcp,
      );
      expect(chat.executable.path, r'C:\tools\agy_acp_server.exe');
      expect(chat.leadingArguments, isEmpty);
    });
  });

  group('antigravityAcpDescriptor & adapter', () {
    test('cliSubcommand matches `acp` and exposes `agy acp --login` only for it', () {
      final spec = antigravityAcpDescriptor.acp!;
      expect(spec.isCliSubcommand(const ['acp']), isTrue);
      expect(spec.isCliSubcommand(const []), isFalse);
      expect(spec.terminalLogin, isNull);
      expect(spec.terminalLoginFor(const []), isNull);
      final login = spec.terminalLoginFor(const ['acp']);
      expect(login, isNotNull);
      expect(login!.arguments, ['--login']);
    });

    test('maps both agy acp modes and legacy agy_acp_server modes', () {
      final spec = antigravityAcpDescriptor.acp!;
      expect(spec.rungOfMode('plan'), PermissionRisk.readOnly);
      expect(spec.rungOfMode('default'), PermissionRisk.ask);
      expect(spec.rungOfMode('accept-edits'), PermissionRisk.acceptEdits);
      expect(spec.rungOfMode('auto_edit'), PermissionRisk.acceptEdits);
      expect(spec.rungOfMode('auto'), PermissionRisk.autoRun);
      expect(spec.rungOfMode('yolo'), PermissionRisk.bypass);
      expect(spec.screenedModes, contains('auto'));

      // agy acp offered modes
      const nativeModes = ['default', 'accept-edits', 'auto', 'plan'];
      expect(spec.modeFor(PermissionRisk.readOnly, nativeModes), 'plan');
      expect(
        spec.modeFor(PermissionRisk.acceptEdits, nativeModes),
        'accept-edits',
      );
      expect(spec.modeFor(PermissionRisk.autoRun, nativeModes), 'auto');

      // standalone agy_acp_server offered modes
      const legacyModes = ['default', 'auto_edit', 'yolo'];
      expect(spec.modeFor(PermissionRisk.readOnly, legacyModes), isNull);
      expect(
        spec.modeFor(PermissionRisk.acceptEdits, legacyModes),
        'auto_edit',
      );
      expect(spec.modeFor(PermissionRisk.bypass, legacyModes), 'yolo');
    });

    test('antigravity-acp adapter wires AntigravityUsageEndpoint', () {
      final adapter = AgentRegistry.builtIn.adapterFor(
        AgentIds.antigravityAcp,
      )!;
      expect(adapter.usage, isNotNull);
      expect(adapter.usage!.endpoint, isA<AntigravityUsageEndpoint>());
    });
  });
}
