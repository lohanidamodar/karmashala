import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/host_hook_endpoint.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// Where local agents' hooks are pointed when local panes are host-backed: at
/// the session host's endpoint, never the app's own route.
void main() {
  late Directory home;
  late HostPaths paths;
  const appRoute = AgentHookEndpoint(port: 47821, token: 'app-route-token');

  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_host_hooks_');
    paths = HostPaths(Directory(p.join(home.path, 'host')))..ensureDirectory();
  });
  tearDown(() => removeTempDirectory(home));

  /// An access in a folder of its own with no binary, so nothing can reach or
  /// start the host of the person running the tests.
  LocalHostSessionAccess inertAccess() => LocalHostSessionAccess(
    paths: paths,
    executable: LocalHostExecutable(
      executableDirectory: p.join(home.path, 'absent'),
      repositoryRoot: p.join(home.path, 'absent'),
    ),
  );

  ProviderContainer containerWith({required bool hostBacked}) {
    final container = ProviderContainer(
      overrides: [
        hostBackedLocalPanesProvider.overrideWithValue(hostBacked),
        localHostSessionAccessProvider.overrideWithValue(inertAccess()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the host names its pane header as the scripts send it', () {
    expect(kHookSessionHeader, kPaneSessionHeader);
    expect(kHookPayloadLimitBytes, kAgentHookPayloadLimitBytes);
  });

  test('with host-backed panes off, hooks still go to the server: it '
      'checkpoints and adopts from them (slice 2b)', () {
    final container = containerWith(hostBacked: false);
    expect(container.read(agentHooksAtHostProvider), isTrue);
    expect(
      installableHookEndpoint(container, appRoute: appRoute),
      isNot(appRoute),
    );
  });

  test('with no server reachable, the app route is what is installed', () {
    final container = ProviderContainer(
      overrides: [localHostSessionAccessProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    expect(container.read(agentHooksAtHostProvider), isFalse);
    expect(installableHookEndpoint(container, appRoute: appRoute), appRoute);
  });

  test('with host-backed panes on and no host yet, only the spool is '
      'installed', () {
    final container = containerWith(hostBacked: true);
    final endpoint = installableHookEndpoint(container, appRoute: null)!;
    expect(endpoint.reaches(EnvironmentKind.localPosix), isFalse);
    expect(endpoint.reaches(EnvironmentKind.windowsNative), isFalse);
    expect(
      endpoint.transportFor(EnvironmentKind.wsl),
      isA<AgentHookSpoolTransport>(),
    );
  });

  group('with host-backed panes on and a host serving hooks', () {
    late HookServer server;
    late List<AgentHookEvent> received;

    setUp(() async {
      received = [];
      server = await HookServer.bind(onHook: received.add);
      await server.endpoint.write(paths.hookEndpointPath);
    });
    tearDown(() => server.close());

    final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;

    Future<String> installed(ProviderContainer container) async {
      final storeHome = p.joinAll([
        home.path,
        ...p.posix.split(claude.store!.homeDirectoryName),
      ]);
      Directory(storeHome).createSync(recursive: true);
      final endpoint = installableHookEndpoint(container, appRoute: null)!;
      expect(
        await const AgentHookInstaller().install(
          descriptor: claude,
          storeHome: storeHome,
          endpoint: endpoint,
          environment: EnvironmentKind.localPosix,
        ),
        isTrue,
      );
      return storeHome;
    }

    test('the installer writes the host\'s URL and token', () async {
      final storeHome = await installed(containerWith(hostBacked: true));
      final file = File(p.join(storeHome, '$agentHookMarker.endpoint'));
      final text = file.readAsStringSync();
      expect(
        text,
        contains(
          'url=http://127.0.0.1:${server.port}/agent-hook'
          '?agent=${AgentIds.claudeCode}',
        ),
      );
      expect(text, contains('token=${server.token}'));
      expect(text, isNot(contains(appRoute.token)));
    });

    test('the generated script, unchanged, delivers to the host', () async {
      final storeHome = await installed(containerWith(hostBacked: true));
      final process = await Process.start(
        'sh',
        [p.join(storeHome, '$agentHookMarker.sh'), 'Stop'],
        environment: {'KARMASHALA_SESSION_ID': 'pane-1'},
      );
      process.stdin.write(jsonEncode({'session_id': 'c1'}));
      await process.stdin.close();
      expect(await process.exitCode, 0);

      final hook = received.single;
      expect(hook.agent, AgentIds.claudeCode);
      expect(hook.event, 'Stop');
      expect(hook.sessionHeader, 'pane-1');
      expect(hook.body, {'session_id': 'c1'});
    }, skip: Platform.isWindows ? 'the POSIX script' : null);
  });
}
