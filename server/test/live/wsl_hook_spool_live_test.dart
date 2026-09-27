@Tags(['live-wsl'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_host/src/hooks/hook_spools.dart';
import 'package:karmashala_host/src/protocol/messages.dart'
    show AgentHookEvent;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The server's WSL hook drain (slice 5a), end to end against a **real**
/// distribution: a hook installed into a **scratch** store home inside WSL
/// (never the owner's own `~/.claude`), fired through the distribution's own
/// `sh`, and drained by `HookSpools` the way `serve` runs it — the running
/// set asked of `wsl.exe`, the spool listed by name over the share, the
/// payload read from inside the distribution. Moved from the app's
/// `live_wsl_hook_test.dart` with the drain. Windows only; skips elsewhere.
void main() {
  final probe = _probeWsl();
  if (probe != null) {
    test('the WSL hook drain', () {}, skip: probe);
    return;
  }

  late String wslHome;
  late String uncHome;

  setUp(() async {
    wslHome = await _wsl(['mktemp', '-d', '-t', 'karmashala-hook-XXXXXX']);
    await _wsl(['mkdir', '-p', '$wslHome/.claude']);
    uncHome = await _wsl(['wslpath', '-w', '$wslHome/.claude']);
  });

  tearDown(() => _wsl(['rm', '-rf', wslHome]));

  test('the server drains a payload a WSL hook spooled', () async {
    final started = DateTime.now().toUtc().subtract(const Duration(seconds: 2));
    final claude = AgentRegistry.builtIn.byId('claudeCode')!;
    const installer = AgentHookInstaller();
    expect(
      await installer.install(
        descriptor: claude,
        storeHome: uncHome,
        endpoint: const AgentHookEndpoint.spoolOnly(),
        environment: EnvironmentKind.wsl,
      ),
      isTrue,
      reason: 'THIS MACHINE: the installer could not write across the share',
    );
    final config =
        jsonDecode(File(p.join(uncHome, 'settings.json')).readAsStringSync())
            as Map<String, Object?>;
    final hook =
        ((((config['hooks']! as Map)['Stop']! as List).single as Map)['hooks']!
                    as List)
                .single
            as Map;
    await _wsl([
      'sh',
      '-c',
      'printf %s \'{"session_id":"live-server-drain"}\' | '
          '{ export HOME=$wslHome; ${hook['command']}; }',
    ]);

    final distribution = await _defaultDistribution();
    expect(distribution, isNotNull);
    final taken = <AgentHookEvent>[];
    final spools = HookSpools(
      sources: () async => [
        HookSpoolSource(
          environmentId: 'wsl:live',
          distribution: distribution!,
          directory: installer.spoolDirectoryFor(claude, uncHome)!.path,
        ),
      ],
      onHook: taken.add,
    );
    addTearDown(spools.close);
    await spools.drainOnce();

    expect(
      taken.map((h) => (h.agent, h.event, h.body['session_id'])),
      [('claudeCode', 'Stop', 'live-server-drain')],
      reason:
          'THE SERVER: the drain did not pick the payload up — the running '
          'gate skipped a running distribution, or the envelope did not parse',
    );
    expect(taken.single.receivedAt.isAfter(started), isTrue);
    expect(
      Directory(
        installer.spoolDirectoryFor(claude, uncHome)!.path,
      ).listSync().where((e) => e.path.endsWith('.json')),
      isEmpty,
      reason: 'a drained payload is a deleted payload',
    );
  });
}

Future<String?> _defaultDistribution() async {
  final result = await Process.run('wsl.exe', ['-l', '--running', '-q']);
  final running = parseWslDistributions('${result.stdout}');
  return running.isEmpty ? null : running.first;
}

String? _probeWsl() {
  if (!Platform.isWindows) return 'The WSL hook path is Windows-only.';
  try {
    final hello = Process.runSync('wsl.exe', ['-e', 'sh', '-c', 'echo ok']);
    if (hello.exitCode != 0 || !'${hello.stdout}'.contains('ok')) {
      return 'No WSL distribution answered.';
    }
  } on ProcessException {
    return 'wsl.exe is not on this machine.';
  }
  return null;
}

Future<String> _wsl(List<String> arguments) async {
  final result = await Process.run('wsl.exe', ['-e', ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('wsl ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}
