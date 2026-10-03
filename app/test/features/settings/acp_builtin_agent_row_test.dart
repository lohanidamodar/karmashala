import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentDiscoveryReport;
import 'package:agent_cli/process.dart' show EnvironmentKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/features/agents/application/acp_agent_providers.dart';
import 'package:karmashala/src/features/agents/application/acp_install_controller.dart';
import 'package:karmashala/src/features/agents/application/agent_installations_controller.dart';
import 'package:karmashala/src/features/settings/presentation/acp_builtin_agent_row.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_http_client.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// A shipped ACP agent the registry ships as a binary offers "Install on
/// `<machine>`" for each machine it is not on; the install goes to the
/// server with the archive for that machine, shows its steps, and a failure
/// in the server's words.
void main() {
  const registryJson = '''
{"agents": [
  {"id": "antigravity-acp", "name": "Google Antigravity", "version": "1.3.0",
   "icon": "https://cdn.example.test/registry/antigravity-acp.svg",
   "distribution": {"binary": {
     "linux-x86_64": {"archive": "https://dl.example.test/linux/agy-1.3.0-linux-x86_64.zip",
                      "cmd": "./agy_acp_server.par", "args": ["--uid="]},
     "windows-x86_64": {"archive": "https://dl.example.test/windows/agy-1.3.0-windows-x86_64.zip",
                        "cmd": "./agy_acp_server.exe"}}}}
]}''';

  late TestMachine db;
  late FakeHttpClient http;
  final descriptor = AgentRegistry.builtIn.byId(AgentIds.antigravityAcp)!;

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    http = FakeHttpClient(body: registryJson);
  });

  Future<List<Override>> overrides() async => [
    await db.server.override(),
    acpRegistryHttpClientProvider.overrideWithValue(() => http),
    acpRegistryPlatformProvider.overrideWithValue('windows-x86_64'),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: await overrides(),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Consumer(
                builder: (context, ref, _) => AcpBuiltInAgentRow(
                  descriptor: descriptor,
                  installs: [
                    for (final install in ref.watch(
                      agentInstallationsControllerProvider,
                    ))
                      if (install.agentId == descriptor.id) install,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('the platform an environment installs for', () {
    const host = 'windows-x86_64';
    expect(
      acpRegistryPlatformForEnvironment(
        EnvironmentKind.windowsNative,
        hostPlatform: host,
      ),
      'windows-x86_64',
    );
    expect(
      acpRegistryPlatformForEnvironment(
        EnvironmentKind.wsl,
        hostPlatform: host,
      ),
      'linux-x86_64',
    );
    expect(
      acpRegistryPlatformForEnvironment(
        EnvironmentKind.localPosix,
        hostPlatform: 'darwin-aarch64',
      ),
      'darwin-aarch64',
    );
    expect(
      acpRegistryPlatformForEnvironment(
        EnvironmentKind.wsl,
        hostPlatform: 'windows-aarch64',
      ),
      'linux-aarch64',
    );
    expect(
      acpRegistryPlatformForEnvironment(
        EnvironmentKind.ssh,
        hostPlatform: host,
      ),
      isNull,
    );
  });

  testWidgets('offers an install per machine it is not on, and nothing is '
      'fetched until one is asked for', (tester) async {
    await pump(tester);
    expect(find.text('Install on Windows'), findsOneWidget);
    expect(find.text('Install on Ubuntu'), findsOneWidget);
    expect(http.requests, 0);
    expect(find.textContaining('Not installed.'), findsOneWidget);
  });

  testWidgets('a machine it is installed on is not offered', (tester) async {
    db.server.installationRows.insert(
      agentInstallation(
        agentId: descriptor.id,
        environmentId: 'wsl:Ubuntu',
        path:
            '/home/me/karmashala/acp/antigravity-acp/1.3.0/agy_acp_server.par',
        version: '1.3.0',
      ),
    );
    await pump(tester);
    expect(find.text('Install on Windows'), findsOneWidget);
    expect(find.text('Install on Ubuntu'), findsNothing);
  });

  testWidgets(
    'Install sends the archive for that machine, shows each step, and the '
    'row then lists the install the server recorded',
    (tester) async {
      db.server.agentWork.onInstall = (request, tellStep) {
        tellStep(AcpInstallStep.unpacking);
        db.server.installationRows.insert(
          agentInstallation(
            id: 'i-wsl',
            agentId: descriptor.id,
            environmentId: request.environmentId,
            path:
                '/home/me/karmashala/acp/antigravity-acp/1.3.0/agy_acp_server.par',
            version: request.version,
          ),
        );
        return const AcpAgentInstalled(
          executablePath:
              '/home/me/karmashala/acp/antigravity-acp/1.3.0/agy_acp_server.par',
          report: AgentDiscoveryReport.empty(),
        );
      };
      await pump(tester);

      await tester.tap(find.text('Install on Ubuntu'));
      await tester.pumpAndSettle();

      final sent = db.server.agentWork.installs.single;
      expect(sent.environmentId, 'wsl:Ubuntu');
      expect(sent.registryId, 'antigravity-acp');
      expect(sent.version, '1.3.0');
      expect(
        sent.archive,
        'https://dl.example.test/linux/agy-1.3.0-linux-x86_64.zip',
      );
      expect(sent.command, './agy_acp_server.par');
      expect(sent.args, ['--uid=']);
      expect(sent.sha256, isNull);
      expect(sent.agentId, descriptor.id);
      expect(http.requestedUrls, [Uri.parse(AcpRegistryCatalog.registryUrl)]);

      expect(find.text('Install on Ubuntu'), findsNothing);
      expect(find.text('Install on Windows'), findsOneWidget);
      expect(find.textContaining('agy_acp_server.par'), findsOneWidget);
      expect(find.textContaining('Downloading'), findsNothing);
    },
  );

  testWidgets('while an install runs the row says which step, in place of '
      'the button', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...await overrides(),
          acpInstallControllerProvider.overrideWith(_Unpacking.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AcpBuiltInAgentRow(
              descriptor: descriptor,
              installs: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Unpacking… on Ubuntu'), findsOneWidget);
    expect(find.text('Install on Ubuntu'), findsNothing);
    expect(find.text('Install on Windows'), findsOneWidget);
  });

  testWidgets('a failure is shown in the server\'s words, and the install '
      'can be asked for again', (tester) async {
    db.server.agentWork.onInstall = (request, _) => throw const DataRefused(
      DataRefusalCode.failed,
      'The download failed (exit 22): 404',
    );
    await pump(tester);

    await tester.tap(find.text('Install on Windows'));
    await tester.pumpAndSettle();
    expect(find.text('The download failed (exit 22): 404'), findsOneWidget);
    expect(find.text('Install on Windows'), findsOneWidget);
    final sent = db.server.agentWork.installs.single;
    expect(sent.environmentId, 'windows');
    expect(
      sent.archive,
      'https://dl.example.test/windows/agy-1.3.0-windows-x86_64.zip',
    );
    expect(sent.command, './agy_acp_server.exe');
    expect(sent.args, isEmpty);
  });

  testWidgets('a registry that cannot be fetched is said so, on the row', (
    tester,
  ) async {
    http = FakeHttpClient(statusCode: 503, body: 'down');
    await pump(tester);
    await tester.tap(find.text('Install on Windows'));
    await tester.pumpAndSettle();
    expect(find.textContaining('registry answered HTTP 503'), findsOneWidget);
    expect(db.server.agentWork.installs, isEmpty);
  });
}

/// A controller mid-install into the WSL distribution.
class _Unpacking extends AcpInstallController {
  @override
  AcpInstallState build() => AcpInstallState(
    steps: {
      acpInstallKey('antigravity-acp', 'wsl:Ubuntu'): AcpInstallStep.unpacking,
    },
  );
}
