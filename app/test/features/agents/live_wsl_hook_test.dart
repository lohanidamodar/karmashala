@Tags(['live-wsl'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_terminal_runtime/launch.dart' show withWslEnv;
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// The whole WSL hook path, end to end, against a **real** distribution.
///
/// Every other test in this area stands something in: a temp directory for a
/// distro home, a Dart `HttpClient` for the agent's `curl`, a fake for the
/// share. Each of those is a fair stand-in for one link, and none of them can
/// tell you whether the chain holds — whether the files this app writes across
/// `\\wsl.localhost` are the files the distribution's own `sh` reads back,
/// whether the command string survives that shell unaltered, and whether what
/// the hook writes there is legible from Windows. Those are the things that
/// were actually broken, and only a real distro answers them.
///
/// So this installs into a **scratch** store home inside WSL (never the user's
/// own `~/.claude`), reads back the command the installer wrote, runs that exact
/// string through the distro's `sh`, drains the spool the way the app does, and
/// asserts the report arrived.
///
/// **Why there is no `curl` in any of this any more.** Until now the hook
/// posted to the host side of the WSL virtual switch, and on this owner's
/// machine that address completes the TCP handshake and then resets the first
/// data segment — for our port and for 135 and 445 alike, and for a bare
/// PowerShell `TcpListener` with no Dart in the picture. Nothing in this
/// repository could open it. The transport now writes a file instead: measured
/// at 3.6 ms per hook inside the distribution, against 2008 ms for the `curl`
/// that then dropped the payload anyway.
///
/// The old measurement is still made, at the bottom, and still reported —
/// because `/mcp` has no such alternative and still depends on that address.
///
/// Skips itself where there is no WSL. It does **not** skip itself when a hook
/// fails to arrive: that is the failure it exists to catch, and skipping it
/// would turn the one measurement nobody else can make into silence.
///
/// How to run it: `tool/live_tests.ps1 -Family wsl`, or see CLAUDE.md §18.
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
    // configuration — and it has to be a *home*, not just a directory, because
    // the installed command names `$HOME/.claude/…`. The store home is
    // `.claude` inside it, exactly as `CliStoreLocator` would build it, and the
    // command below is run with `HOME` pointed here so the path it expands is
    // this one.
    wslHome = await _wsl(['mktemp', '-d', '-t', 'karmashala-hook-XXXXXX']);
    await _wsl(['mkdir', '-p', '$wslHome/.claude']);
    uncHome = await _wsl(['wslpath', '-w', '$wslHome/.claude']);
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    removeTempDirectory(tmp);
    await _wsl(['rm', '-rf', wslHome]);
  });

  test('a hook installed in WSL reaches the app', () async {
    final endpoint = server.hookEndpoint!;
    final claude = AgentRegistry.builtIn.byId('claudeCode')!;
    const installer = AgentHookInstaller();

    final wrote = await installer.install(
      descriptor: claude,
      storeHome: uncHome,
      endpoint: endpoint,
      environment: EnvironmentKind.wsl,
    );
    expect(
      wrote,
      isTrue,
      reason:
          'THIS MACHINE, not the app: the installer could not write and read '
          'back its three files across \\\\wsl.localhost. Check that the share '
          'is reachable and the distro home is writable — this is the one '
          'link the transport rests on.',
    );

    // Exactly what the agent will run, read back out of the config file the
    // installer wrote rather than rebuilt here.
    final config =
        jsonDecode(File(p.join(uncHome, 'settings.json')).readAsStringSync())
            as Map<String, Object?>;
    final command =
        ((((config['hooks']! as Map)['Stop']! as List).single as Map)['hooks']!
                    as List)
                .single
            as Map;
    // The entry is a constant, so what the transport *is* gets asserted where
    // it lives: the endpoint file the generated script reads when the hook
    // fires. All three files cross the share, and all three are read from
    // inside the distribution — which is the link this suite exists to test.
    expect(command['command'], contains(agentHookMarker));
    final endpointText = File(
      p.join(uncHome, '$agentHookMarker.endpoint'),
    ).readAsStringSync();
    expect(endpointText, contains('spool=$agentHookMarker.spool'));
    expect(
      endpointText,
      isNot(contains('token=')),
      reason:
          'nothing here crosses a network, so nothing here needs a credential '
          'at rest inside somebody else\'s filesystem',
    );

    // `HOME` is the scratch home, so `$HOME/.claude/…` in the command names
    // the store this test installed into and never the owner's own.
    final payload = r'{"session_id":"live-wsl","cwd":"/tmp"}';
    final hook = command['command']! as String;
    final output = await _wslRaw([
      'sh',
      '-c',
      "printf %s '$payload' | ${_underHome(wslHome, hook)}; echo \"exit=\$?\"",
    ]);

    // A hook must print nothing: an agent that can decide something reads its
    // own hook's stdout for that decision.
    expect(
      output,
      'exit=0',
      reason:
          'THE APP: the distro shell said something back. The command string '
          'did not survive that shell, which is exactly what this test exists '
          'to catch.\n\n$output',
    );

    // The Windows side, exactly as the app does it: list the spool over the
    // share, read each payload, delete it, apply it.
    final spool = Directory(p.join(uncHome, '$agentHookMarker.spool'));
    final events = await const AgentHookSpool().drain(spool);
    if (events.isEmpty) {
      fail(_verdict(spool, uncHome, wslHome, hook));
    }
    for (final event in events) {
      container
          .read(agentHookReceiverProvider)
          .handle(
            agentId: event.agentId,
            event: event.event,
            body: event.body,
            observedAt: event.firedAt,
          );
    }

    expect(
      reports.latest('claudeCode', 'live-wsl')?.status,
      AgentActivityStatus.idle,
      reason:
          'THE APP: the payload crossed the share intact but the report did '
          'not land in the registry a Windows callback lands in.',
    );
    expect(
      spool.listSync(),
      isEmpty,
      reason: 'a drained payload is a deleted payload, or the spool grows',
    );
  });

  test('a Windows-side KARMASHALA_SESSION_ID reaches the spool through '
      'WSLENV', () async {
    // The crossing an agent pane makes: the variable set on the `wsl.exe`
    // process with the app's own `withWslEnv`, read by the hook inside.
    final claude = AgentRegistry.builtIn.byId('claudeCode')!;
    expect(
      await const AgentHookInstaller().install(
        descriptor: claude,
        storeHome: uncHome,
        endpoint: server.hookEndpoint!,
        environment: EnvironmentKind.wsl,
      ),
      isTrue,
    );
    final config =
        jsonDecode(File(p.join(uncHome, 'settings.json')).readAsStringSync())
            as Map<String, Object?>;
    final hook =
        ((((((config['hooks']! as Map)['Stop']! as List).single
                            as Map)['hooks']!
                        as List)
                    .single
                as Map)['command']!
            as String);
    final spool = Directory(p.join(uncHome, '$agentHookMarker.spool'));

    Future<String?> fireWith(Map<String, String> environment) async {
      final result = await Process.run('wsl.exe', [
        '-e',
        'sh',
        '-c',
        'printf %s \'{"session_id":"live-pane"}\' | '
            '${_underHome(wslHome, hook)}',
      ], environment: environment);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final events = await const AgentHookSpool().drain(spool);
      expect(events, hasLength(1));
      return events.single.paneSessionId;
    }

    expect(
      await fireWith(
        withWslEnv({'KARMASHALA_SESSION_ID': 'e8b49ed3-live-crossing'}),
      ),
      'e8b49ed3-live-crossing',
      reason:
          'THE APP: the variable was named in WSLENV and still did not reach '
          'the hook inside the distribution.',
    );
    // And WSLENV is what carried it: without it the distro never sees it.
    expect(
      await fireWith({
        'KARMASHALA_SESSION_ID': 'e8b49ed3-live-crossing',
        'WSLENV': '',
      }),
      isNull,
    );
  });

  test('uninstall leaves nothing of ours in the distribution', () async {
    const installer = AgentHookInstaller();
    final claude = AgentRegistry.builtIn.byId('claudeCode')!;
    await installer.install(
      descriptor: claude,
      storeHome: uncHome,
      endpoint: server.hookEndpoint!,
      environment: EnvironmentKind.wsl,
    );
    // A payload nobody drained, so the removal has to take a non-empty
    // directory with it.
    File(
      p.join(uncHome, '$agentHookMarker.spool', '1-0.json'),
    ).writeAsStringSync('agent=claudeCode\nevent=Stop\n\n{}');

    await installer.uninstall(descriptor: claude, storeHome: uncHome);

    final left = await _wsl([
      'sh',
      '-c',
      'ls -A $wslHome/.claude | grep $agentHookMarker || true',
    ]);
    expect(left, isEmpty, reason: 'left behind in the distribution: $left');
  });

  test('the WSL switch address is still measured, for /mcp', () async {
    // Hooks left this address; `/mcp` has not, and a WSL session's tools still
    // depend on it. So the measurement stays, and it stays named: this is the
    // number that decides whether an agent in a distribution can drive the app
    // at all.
    final port = server.hookEndpoint!.port;
    final host = server.wslHost?.address;
    if (host == null) {
      markTestSkipped(
        'No WSL switch adapter is bound, so there is nothing to measure. '
        'WSL sessions get no MCP tools on this machine.',
      );
      return;
    }
    final probe = await _wslRaw([
      'sh',
      '-c',
      'curl -sS -m 5 -o /dev/null http://$host:$port/mcp; echo "exit=\$?"',
    ]);
    final code = RegExp(r'exit=(\d+)').firstMatch(probe)?.group(1) ?? '?';

    // Reported, never asserted. A shut switch is the machine's, and failing
    // here would say the app is broken when it is not — which is the mistake
    // that cost a day in the other direction.
    // ignore: avoid_print
    print(
      code == '0'
          ? 'WSL switch $host:$port answers: MCP works for WSL sessions here.'
          : 'WSL switch $host:$port does NOT answer from inside the distro '
                '(curl exit $code). THIS MACHINE, not the app: hooks no longer '
                'use it, but WSL sessions get no MCP tools until it opens.\n'
                '$probe',
    );
  });
}

/// What a spool that stayed empty **means**.
///
/// The point of running against a real distribution is that it can tell the
/// failures apart, and a bare `Expected: non-empty / Actual: []` cannot. Every
/// branch names which side is at fault, because the wrong attribution is
/// expensive in both directions: a machine problem filed as a bug wastes a day,
/// and an app problem waved off as "the machine again" is how this path
/// silently degraded in the first place.
String _verdict(
  Directory spool,
  String uncHome,
  String wslHome,
  String command,
) {
  if (!spool.existsSync()) {
    return 'THE APP: the installer reported success and there is no spool '
        'directory at ${spool.path}. `_writeCallbackFiles` is meant to create '
        'it before the endpoint file that names it.';
  }
  final leftovers = spool
      .listSync()
      .map((e) => p.basename(e.path))
      .toList(growable: false);
  if (leftovers.isNotEmpty) {
    return 'THE APP: the hook wrote ${leftovers.join(', ')} and the drain read '
        'none of it. A `.part` left behind means the `mv` did not run; a '
        '`.json` left behind means the envelope did not parse.';
  }
  final endpointFile = File(p.join(uncHome, '$agentHookMarker.endpoint'));
  if (!endpointFile.existsSync()) {
    return 'THE APP: there is no endpoint file, so the script exited zero '
        'without writing. The install said it wrote one.';
  }
  return 'THE APP: the script ran, printed nothing, exited zero and left the '
      'spool empty. It reads its endpoint file relative to \$0, so the usual '
      'cause is that `HOME=$wslHome` did not put the command\'s '
      '`\$HOME/.claude` where this test installed.\n\n'
      'command: $command\n'
      'endpoint file:\n${endpointFile.readAsStringSync()}';
}

/// [command] run with `HOME` pointed at [home], **exported first**.
///
/// `HOME=x sh "$HOME/…"` does not do this: a prefix assignment applies to the
/// command's environment, and the argument was already expanded from the
/// caller's `HOME` by then — so the hook this test installed into a scratch
/// store went looking in the owner's real one and exited 127. Exporting in a
/// statement of its own is what makes the second statement see it.
String _underHome(String home, String command) =>
    '{ export HOME=$home; $command; }';

/// One command inside the default distribution, **without** throwing on a
/// non-zero exit. [_wsl]'s counterpart for the diagnosis path, where the exit
/// code is the answer rather than a broken fixture.
Future<String> _wslRaw(List<String> arguments) async {
  final result = await Process.run('wsl.exe', ['-e', ...arguments]);
  return '${result.stdout}${result.stderr}'.trim();
}

/// Why this suite cannot run here, or null when it can.
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

/// One command inside the default distribution, trimmed. Throws on failure so a
/// broken fixture cannot look like a broken feature.
///
/// Asynchronous, and that is load-bearing rather than stylistic: the control
/// server under test serves on this isolate's event loop, so a `runSync` here
/// blocks the very server the request inside WSL is dialling.
Future<String> _wsl(List<String> arguments) async {
  final result = await Process.run('wsl.exe', ['-e', ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('wsl ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}
