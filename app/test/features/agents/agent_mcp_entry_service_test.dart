import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:karmashala/src/features/agents/application/agent_mcp_entry_service.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import '../../support/test_machine.dart';

class _StubLocator implements CliStoreLocator {
  _StubLocator(this.stores);

  final List<CliStore> stores;
  var calls = 0;

  @override
  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async {
    calls++;
    return stores;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _bridge = r'C:\Karmashala\karmashala_mcp.exe';

/// The agy entry sweep against a temporary home: **nothing here touches the
/// owner's own ~/.gemini** — the store locator is stubbed, and the probe case
/// proves a probe never asks it.
void main() {
  late TestMachine db;
  late Override data;
  late Directory home;

  setUp(() async {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    home = Directory.systemTemp.createTempSync('karmashala_mcp_entry_svc_');
    data = await db.server.override();
  });
  tearDown(() => removeTempDirectory(home));

  String localId() => db.server.environmentRows
      .getAll()
      .firstWhere((e) => isLocalHost(e.kind))
      .id;
  String agyStore() => p.join(home.path, '.gemini', 'antigravity-cli');
  File config() =>
      File(p.join(home.path, '.gemini', 'config', 'mcp_config.json'));
  Map<String, Object?> servers() =>
      (jsonDecode(config().readAsStringSync()) as Map)['mcpServers']
          as Map<String, Object?>;

  ProviderContainer containerWith(
    CliStoreLocator locator, {
    ProbeMode probe = ProbeMode.off,
    String? bridge = _bridge,
  }) {
    final container = ProviderContainer(
      overrides: [
        data,
        cliStoreLocatorProvider.overrideWithValue(locator),
        probeModeProvider.overrideWithValue(probe),
        karmashalaBridgePathProvider.overrideWithValue(bridge),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  _StubLocator agyHere() => _StubLocator([
    CliStore(
      environmentId: localId(),
      homesByAgentId: {'antigravity': agyStore()},
    ),
  ]);

  test('the sweep adds the entry beside the person\'s own servers', () async {
    Directory(agyStore()).createSync(recursive: true);
    config().parent.createSync(recursive: true);
    config().writeAsStringSync(
      '{"mcpServers": {"dart": {"command": "dart.exe", "args": ["mcp-server"]}}}',
    );
    final container = containerWith(agyHere());

    final report = await container.read(agentMcpEntryServiceProvider).sweep();

    expect(servers().keys, ['dart', 'karmashala']);
    expect(servers()['karmashala'], {
      'command': _bridge,
      'args': ['--session-only'],
    });
    expect(report.entries.single.state, KarmashalaMcpEntryState.current);
    expect(report.entries.single.path, config().path);
    expect(container.read(agentMcpEntryReportProvider), same(report));
  });

  test('remove takes it out and keeps it out; add puts it back', () async {
    Directory(agyStore()).createSync(recursive: true);
    final container = containerWith(agyHere());
    final service = container.read(agentMcpEntryServiceProvider);
    await service.sweep();

    final removed = await service.removeAll();
    expect(removed.entries.single.state, KarmashalaMcpEntryState.absent);
    expect(servers(), isEmpty);
    expect(container.read(settingsControllerProvider).agentMcpEntries, isFalse);

    // The next launch's sweep reads, and writes nothing back.
    final next = await service.sweep();
    expect(next.entries.single.state, KarmashalaMcpEntryState.absent);
    expect(servers(), isEmpty);

    await service.restore();
    expect(servers().keys, ['karmashala']);
    expect(container.read(settingsControllerProvider).agentMcpEntries, isTrue);
  });

  test('without the bridge beside the app nothing is written', () async {
    Directory(agyStore()).createSync(recursive: true);
    final container = containerWith(agyHere(), bridge: null);

    final report = await container.read(agentMcpEntryServiceProvider).sweep();

    expect(config().existsSync(), isFalse);
    expect(report.entries.single.problem, contains('not beside this app'));
  });

  test('a probe writes only under its own data folder', () async {
    final locator = agyHere();
    final probeData = p.join(home.path, 'probe-data');
    final container = containerWith(
      locator,
      probe: ProbeMode(enabled: true, dataDirectory: probeData),
    );

    final report = await container.read(agentMcpEntryServiceProvider).sweep();

    expect(locator.calls, 0, reason: 'a probe never locates the real stores');
    expect(config().existsSync(), isFalse);
    final probeFile = File(
      p.join(probeData, 'probe-home', '.gemini', 'config', 'mcp_config.json'),
    );
    expect(report.entries.single.path, probeFile.path);
    expect(
      (jsonDecode(probeFile.readAsStringSync()) as Map)['mcpServers'],
      contains('karmashala'),
    );
  });
}
