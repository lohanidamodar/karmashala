@Tags(['live-wsl'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_installer.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The whole WSL hook path, end to end, against a **real** distribution.
///
/// Every other test in this area stands something in: `127.0.0.2` for the
/// switch address, a temp directory for a distro home, a Dart `HttpClient` for
/// the agent's `curl`. Each of those is a fair stand-in for one link, and none
/// of them can tell you whether the chain holds — whether the address a Windows
/// process binds is dialable from inside the distribution's own network
/// namespace, and whether the command string this app writes into an agent's
/// config survives that distribution's shell unaltered. Those are the two
/// things that were actually broken, and only a real distro answers them.
///
/// So this installs into a **scratch** store home inside WSL (never the user's
/// own `~/.claude`), reads back the command the installer wrote, runs that exact
/// string through the distro's `sh`, and asserts the report arrived.
///
/// Since Loop 71 that string names a generated script rather than spelling a
/// `curl`, so this now covers three files crossing the `\\wsl.localhost` share
/// instead of one — the entry, the script, and the endpoint file the script
/// reads at fire time — and the script's `401` probe as well as its callback.
/// `HOME` is set to the scratch home for the run, because the command names
/// `$HOME/.claude/…` and the whole point of naming it that way is that the app
/// and the agent disagree about how to spell the same directory.
///
/// Skips itself where there is no WSL, no `curl` inside it, or no switch
/// address — the same shape as `live_ssh_test.dart`.
void main() {
  final probe = _probeWsl();
  if (probe != null) {
    test('live WSL hook test is skipped', () {}, skip: probe);
    return;
  }

  late Directory tmp;
  late ProviderContainer container;
  late LauncherControlServer server;
  late AgentHookReports reports;
  late String wslHome;
  late String uncHome;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_livewsl_');
    container = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
    );
    reports = container.read(agentHookReportsProvider);
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
    // A `$HOME` of our own, so nothing here can touch the user's real agent
    // configuration — and it has to be a *home*, not just a directory, now
    // that the installed command names `$HOME/.claude/…` rather than spelling
    // an address inline. The store home is `.claude` inside it, exactly as
    // `CliStoreLocator` would build it, and the command below is run with
    // `HOME` pointed here so the path it expands is this one.
    wslHome = await _wsl(['mktemp', '-d', '-t', 'karmashala-hook-XXXXXX']);
    await _wsl(['mkdir', '-p', '$wslHome/.claude']);
    uncHome = await _wsl(['wslpath', '-w', '$wslHome/.claude']);
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    tmp.deleteSync(recursive: true);
    await _wsl(['rm', '-rf', wslHome]);
  });

  test('a hook installed in WSL reaches the app', () async {
    final endpoint = server.hookEndpoint!;
    expect(
      endpoint.wslHost,
      isNotNull,
      reason: 'the switch interface has to be bound before anything is written',
    );

    final installed = await const AgentHookInstaller().install(
      descriptor: AgentRegistry.builtIn.byId('claudeCode')!,
      storeHome: uncHome,
      endpoint: endpoint,
      environment: EnvironmentKind.wsl,
    );
    expect(installed, isTrue);

    // Exactly what the agent will run, read back out of the config file the
    // installer wrote rather than rebuilt here.
    final config =
        jsonDecode(File(p.join(uncHome, 'settings.json')).readAsStringSync())
            as Map<String, Object?>;
    final command =
        ((((config['hooks']! as Map)['Stop']! as List).single
                        as Map)['hooks']!
                    as List)
                .single
            as Map;
    // The entry is a constant now, so the address is asserted where it lives:
    // the endpoint file the generated script reads when the hook fires. Both
    // of those are written across the `\\wsl.localhost` share and read from
    // inside the distribution, which is the link this suite exists to test.
    expect(command['command'], contains(agentHookMarker));
    expect(command['command'], isNot(contains(endpoint.wslHost!)));
    expect(
      File(p.join(uncHome, '$agentHookMarker.endpoint')).readAsStringSync(),
      contains(endpoint.wslHost!),
    );

    // `HOME` is the scratch home, so `$HOME/.claude/…` in the command names
    // the store this test installed into and never the owner's own.
    final output = await _wsl([
      'sh',
      '-c',
      'printf %s \'{"session_id":"live-wsl","cwd":"/tmp"}\' | '
          'HOME=$wslHome ${command['command']}',
    ]);

    // The script discards the endpoint's reply on purpose — a hook that can
    // decide something reads its own stdout for that decision — so the arrival
    // is asserted on the registry and not on what came back.
    expect(output, isEmpty);
    expect(
      reports.latest('claudeCode', 'live-wsl')?.status,
      AgentActivityStatus.idle,
      reason: 'the callback has to land in the same registry a Windows one does',
    );
  });

  test('the same hook cannot be reached from loopback inside WSL', () async {
    // The measurement the whole design rests on: `127.0.0.1` inside a
    // distribution is the distribution's own loopback, so the URL that is right
    // for a Windows-native pane is refused from here.
    final endpoint = server.hookEndpoint!;
    final result = await Process.run('wsl.exe', [
      '-e',
      'sh',
      '-c',
      'curl -sS -m 2 -o /dev/null '
          'http://127.0.0.1:${endpoint.port}/agent-hook; echo "exit=\$?"',
    ]);

    expect('${result.stdout}${result.stderr}', contains('exit=7'));
  });
}

/// Why this suite cannot run here, or null when it can.
String? _probeWsl() {
  if (!Platform.isWindows) return 'The WSL hook path is Windows-only.';
  try {
    final hello = Process.runSync('wsl.exe', ['-e', 'sh', '-c', 'echo ok']);
    if (hello.exitCode != 0 || !'${hello.stdout}'.contains('ok')) {
      return 'No WSL distribution answered.';
    }
    final curl = Process.runSync('wsl.exe', ['-e', 'sh', '-c', 'command -v curl']);
    if (curl.exitCode != 0) {
      return 'The WSL distribution has no curl, which is what a hook runs.';
    }
  } on ProcessException {
    return 'wsl.exe is not on this machine.';
  }
  return null;
}

/// One command inside the default distribution, trimmed. Throws on failure so a
/// broken fixture cannot look like a broken feature.
///
/// Asynchronous, and that is load-bearing rather than stylistic: the control
/// server under test serves on this isolate's event loop, so a `runSync` here
/// blocks the very server the `curl` inside WSL is dialling and the call times
/// out having connected to nothing that can answer.
Future<String> _wsl(List<String> arguments) async {
  final result = await Process.run('wsl.exe', ['-e', ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('wsl ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}
