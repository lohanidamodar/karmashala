import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/capacity/launch_slots.dart';
import 'package:karmashala_host/src/sessions/launch/capacity/session_launch_gate.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

class _Clock implements Clock {
  DateTime now = DateTime.utc(2026, 10, 9, 12);
  @override
  DateTime nowUtc() => now;
}

/// A child that exits when it is signalled, as a real one does.
class _Pty implements PtyLauncher {
  final started = <PtySpawnRequest>[];
  final handles = <_Handle>[];
  var _pid = 1000;

  @override
  PtyHandle start(PtySpawnRequest request) {
    started.add(request);
    final handle = _Handle(_pid++, request);
    handles.add(handle);
    return handle;
  }
}

class _Handle extends FakePtyHandle {
  _Handle(super.pid, super.request);
  @override
  void kill([int signal = 15]) {
    super.kill(signal);
    finish(128 + signal);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The gate over the real launch path: real rows, a fake PTY, a fake clock.
void main() {
  final t0 = DateTime.utc(2026, 10, 9, 12);
  final local = Platform.isWindows ? 'windowsNative' : 'localPosix';

  late AppDatabase database;
  late SessionRegistry registry;
  late _Pty pty;
  late Directory temp;
  late ServerSessionLauncher launches;
  late SessionLaunchGate gate;
  late _Clock clock;
  var ids = 0;

  (ServerSessionLauncher, SessionLaunchGate) build() {
    final rows = CheckoutRows(database);
    final sessions = SessionDao(database);
    late ServerSessionLauncher built;
    final gate = SessionLaunchGate(
      limits: () => launchLimitsIn(database.readMetadata('settings.v1')),
      occupants: () => liveSlotHolders(
        sessions: sessions,
        rows: rows,
        holds: (id) => built.runsHere(id),
        activityOf: (_) => null,
      ),
      clock: clock,
      readQueue: () => database.readMetadata(kLaunchQueueKey),
      writeQueue: (json) => database.writeMetadata(kLaunchQueueKey, json),
    );
    built = ServerSessionLauncher(
      gate: gate,
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: sessions,
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        windows: false,
      ),
      registry: registry,
      sessions: sessions,
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      directoryPresent: (_) => true,
      pathProbe: const _Everywhere(),
    );
    gate.onGranted(
      kSessionStartLaunchKind,
      built.startGranted,
      onCancelled: built.waitCancelled,
    );
    gate.start();
    return (built, gate);
  }

  void limit(Map<String, Object?> limits) => database.writeMetadata(
    'settings.v1',
    jsonEncode({kLaunchLimitsSettingsKey: limits}),
  );

  setUp(() {
    ids = 0;
    clock = _Clock();
    temp = Directory.systemTemp.createTempSync('gated_launch_test');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['local', local, 'Windows', '$t0'],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    pty = _Pty();
    registry = SessionRegistry(launcher: pty);
    (launches, gate) = build();
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    await gate.dispose();
    database.close();
    temp.deleteSync(recursive: true);
  });

  SessionStartSpec spec(String title, {String prompt = 'go'}) =>
      SessionStartSpec(
        repositoryId: 'r1',
        installationId: 'a1',
        title: title,
        prompt: prompt,
      );
  Session row(String id) => SessionDao(database).getById(id)!;

  test('nothing set: both start', () async {
    await launches.start(spec('One'));
    final second = await launches.start(spec('Two'));
    expect(second.waiting, isFalse);
    expect(pty.started, hasLength(2));
  });

  test('limit 1: the second waits with its reason, and starts when the first '
      'ends', () async {
    limit({'global': 1});
    final first = await launches.start(spec('One'));
    final second = await launches.start(spec('Two', prompt: 'second'));
    expect(first.waiting, isFalse);
    expect(second.waiting, isTrue);
    expect(second.wait!.reason, 'Waiting for a slot: 1 of 1 is busy (One)');
    expect(second.wait!.place, 1);
    expect(row(second.sessionId).status, SessionStatus.created);
    expect(pty.started, hasLength(1));

    await launches.end(first.sessionId);
    gate.pump();
    await _settle();
    expect(pty.started, hasLength(2));
    expect(pty.started.last.argv.join(' '), contains('second'));
    expect(row(second.sessionId).status, SessionStatus.running);
    expect(gate.snapshot().waiters, isEmpty);
  });

  test('starts at once never oversubscribe', () async {
    limit({'global': 2});
    final all = await Future.wait([
      for (var i = 0; i < 5; i++) launches.start(spec('S$i')),
    ]);
    expect(all.where((s) => !s.waiting), hasLength(2));
    expect(pty.started, hasLength(2));
    expect(gate.snapshot().waiters, hasLength(3));
  });

  test('a resume waits too, on its own row', () async {
    limit({'global': 1});
    await launches.start(spec('One'));
    SessionDao(database).insert(
      Session(
        id: 'old',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Old',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'conv-old',
      ),
    );
    final resumed = await launches.resume('old');
    expect(resumed.waiting, isTrue);
    expect(resumed.sessionId, 'old');
    expect(row('old').status, SessionStatus.completed);
  });

  test('Start anyway starts a waiting session over the limit', () async {
    limit({'global': 1});
    await launches.start(spec('One'));
    final second = await launches.start(spec('Two'));
    expect(gate.startAnyway(second.wait!.ticketId), isTrue);
    await _settle();
    expect(pty.started, hasLength(2));
    expect(gate.snapshot().running, 2);
  });

  test('ending a waiting session cancels its wait and its row', () async {
    limit({'global': 1});
    await launches.start(spec('One'));
    final second = await launches.start(spec('Two'));
    await launches.end(second.sessionId);
    expect(row(second.sessionId).status, SessionStatus.cancelled);
    expect(gate.snapshot().waiters, isEmpty);
  });

  test('the queue survives a restart and starts once a slot frees', () async {
    limit({'global': 1});
    final first = await launches.start(spec('One'));
    final second = await launches.start(spec('Two', prompt: 'after'));
    await gate.dispose();
    // The server restarts: what ran died with it.
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    registry = SessionRegistry(launcher: pty);
    SessionDao(database).updateStatus(first.sessionId, SessionStatus.unknown);
    (launches, gate) = build();
    await _settle();
    expect(pty.started, hasLength(2));
    expect(pty.started.last.argv.join(' '), contains('after'));
    expect(row(second.sessionId).status, SessionStatus.running);
  });

  test('a background start waits behind a person\'s', () async {
    limit({'global': 1});
    final first = await launches.start(spec('One'));
    final bg = await launches.start(
      spec('Agent child'),
      priority: LaunchPriority.background,
    );
    clock.now = clock.now.add(const Duration(minutes: 1));
    final person = await launches.start(spec('Person'));
    expect(gate.snapshot().waiterFor(person.sessionId)!.place, 1);
    expect(gate.snapshot().waiterFor(bg.sessionId)!.place, 2);
    await launches.end(first.sessionId);
    gate.pump();
    await _settle();
    expect(row(person.sessionId).status, SessionStatus.running);
    expect(row(bg.sessionId).status, SessionStatus.created);
  });
}
