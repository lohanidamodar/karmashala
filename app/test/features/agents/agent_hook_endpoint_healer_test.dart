import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_endpoint_healer.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_sweep.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_core/logging.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import '../../support/test_machine.dart';

class _StubLocator implements CliStoreLocator {
  _StubLocator(this.stores);

  final List<CliStore> stores;

  @override
  Future<List<CliStore>> locate(
    List<ExecutionEnvironment> environments,
  ) async => stores;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Something deleted every agent's endpoint file while the app ran, and status
/// stayed silent until the next launch. The running app now notices and heals.
void main() {
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');

  late TestMachine db;
  late Override data;
  late Directory claudeHome;

  setUp(() async {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    claudeHome = Directory.systemTemp.createTempSync('karmashala_heal_');
    data = await db.server.override();
  });
  tearDown(() => removeTempDirectory(claudeHome));

  File endpointFile() =>
      File(p.join(claudeHome.path, '$agentHookMarker.endpoint'));

  String localId() => db.server.environmentRows
      .getAll()
      .firstWhere((e) => isLocalHost(e.kind))
      .id;

  ProviderContainer containerWith({String? environmentId, bool probe = false}) {
    final container = ProviderContainer(
      overrides: [
        data,
        cliStoreLocatorProvider.overrideWithValue(
          _StubLocator([
            CliStore(
              environmentId: environmentId ?? localId(),
              homesByAgentId: {AgentIds.claudeCode: claudeHome.path},
            ),
          ]),
        ),
        if (probe) probeModeProvider.overrideWithValue(ProbeMode.on),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<String> installed(ProviderContainer container) async {
    await sweepAgentHooks(container, endpoint);
    expect(endpointFile().existsSync(), isTrue, reason: 'nothing to heal');
    return endpointFile().readAsStringSync();
  }

  test('nothing is checked before a sweep has installed anything', () async {
    expect(await healAgentHookEndpoints(containerWith()), isFalse);
  });

  test('a deleted endpoint file is rewritten, and the app says so', () async {
    final records = <LogRecord>[];
    AppLogger.initialize(level: Level.ALL, onRecord: records.add);
    addTearDown(AppLogger.initialize);
    final container = containerWith();
    final written = await installed(container);
    endpointFile().deleteSync();

    final healed = await healAgentHookEndpoints(
      container,
      logger: AppLogger.named('agent-hooks'),
    );

    expect(healed, isTrue);
    expect(endpointFile().readAsStringSync(), written);
    expect(
      records.where((r) => r.level >= Level.WARNING).map((r) => r.message),
      contains(contains(AgentIds.claudeCode)),
    );
    expect(records.map((r) => r.message), everyElement(isNot(contains('tok'))));
  });

  test('an edited endpoint file is rewritten', () async {
    final container = containerWith();
    final written = await installed(container);
    endpointFile().writeAsStringSync('url=\ntoken=\n');

    expect(await healAgentHookEndpoints(container), isTrue);
    expect(endpointFile().readAsStringSync(), written);
  });

  test('a current endpoint file is left alone', () async {
    final container = containerWith();
    await installed(container);
    final before = endpointFile().lastModifiedSync();

    expect(await healAgentHookEndpoints(container), isFalse);
    expect(endpointFile().lastModifiedSync(), before);
  });

  test(
    'a WSL store is not read on the timer: a touch wakes the distro',
    () async {
      final wsl = wslEnv();
      db.server.environmentRows.upsert(wsl);
      final container = containerWith(environmentId: wsl.id);
      await installed(container);
      endpointFile().deleteSync();

      expect(await healAgentHookEndpoints(container), isFalse);
      expect(endpointFile().existsSync(), isFalse);
    },
  );

  test('a probe heals nothing: the stores are the real app\'s', () async {
    final container = containerWith(probe: true);
    // A probe's sweep installs nothing, so stand in the real app's file.
    await installed(containerWith());
    await sweepAgentHooks(container, endpoint);
    endpointFile().deleteSync();

    expect(await healAgentHookEndpoints(container), isFalse);
    expect(endpointFile().existsSync(), isFalse);
  });

  group('the healer', () {
    test('rewrites a deleted file on its own, until stopped', () async {
      final container = containerWith();
      final written = await installed(container);
      final healer = AgentHookEndpointHealer(
        container,
        interval: const Duration(milliseconds: 20),
      )..start();
      addTearDown(healer.stop);

      endpointFile().deleteSync();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!endpointFile().existsSync() &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(endpointFile().readAsStringSync(), written);

      await healer.stop();
      endpointFile().deleteSync();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(endpointFile().existsSync(), isFalse);
    });

    // A quit stops the healer and then retires the endpoint files: a check
    // still in flight must not write one back after that.
    test('stop waits for a check already running', () async {
      final container = containerWith();
      await installed(container);
      final healer = AgentHookEndpointHealer(container);
      endpointFile().deleteSync();

      var checkDone = false;
      unawaited(healer.check().whenComplete(() => checkDone = true));
      await healer.stop();

      expect(checkDone, isTrue);
    });
  });
}
