import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_host/src/devices/server_device_claims.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  void advance(Duration by) => now = now.add(by);
  @override
  DateTime nowUtc() => now.toUtc();
}

/// The one claims registry on the server's machine (slice 4a): holders named
/// from the sessions store, every change told, released when a session ends.
void main() {
  late ToolHarness harness;
  late _Clock clock;
  late List<DataChange> told;
  late ServerDeviceClaims claims;

  setUp(() {
    harness = ToolHarness();
    clock = _Clock(DateTime.utc(2026, 9, 27, 12));
    told = [];
    claims = ServerDeviceClaims(
      database: harness.db,
      tell: told.addAll,
      clock: clock,
    );
  });

  tearDown(() {
    claims.close();
    harness.dispose();
  });

  List<DeviceClaimsChanged> changes() =>
      told.whereType<DeviceClaimsChanged>().toList();

  Session row(String id, SessionStatus status) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Fix login',
    useWorktree: false,
    status: status,
    createdAt: clock.now,
  );

  test('a holder is named from the sessions store', () {
    claims.claim(
      deviceId: 'emulator-5554',
      sessionId: 's1',
      verb: 'device_tap',
    );
    final hold = changes().single.holds.single;
    expect(hold.holderSessionId, 's1');
    expect(hold.holderTitle, 'Fix login');
    expect(hold.lastVerb, 'device_tap');
  });

  test('taking and releasing are told; renewing is not', () {
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    expect(changes(), hasLength(1));
    clock.advance(const Duration(seconds: 5));
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_type');
    claims.registry.observed(deviceId: 'd', sessionId: 's1');
    expect(changes(), hasLength(1), reason: 'a renewal changes no holder');
    claims.registry.release('s1');
    expect(changes(), hasLength(2));
    expect(changes().last.holds, isEmpty);
  });

  test('a lapse is told when a sweep finds it', () {
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    clock.advance(kDeviceClaimLapse);
    claims.registry.sweep();
    expect(changes(), hasLength(2));
    expect(changes().last.holds, isEmpty);
  });

  test('an ended session\'s row releases its devices, a turn later', () async {
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    claims.watch([SessionRowChanged(row('s1', SessionStatus.completed))]);
    // Deferred: not told inside the batch that ended the session.
    expect(claims.registry.held, hasLength(1));
    await pumpEventQueue();
    expect(claims.registry.held, isEmpty);
    expect(changes().last.holds, isEmpty);
  });

  test('a live session\'s row keeps its devices', () async {
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    claims.watch([SessionRowChanged(row('s1', SessionStatus.running))]);
    await pumpEventQueue();
    expect(claims.registry.held, hasLength(1));
  });

  test('a removed session releases its devices', () async {
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    claims.watch([const SessionRowRemoved('s1')]);
    await pumpEventQueue();
    expect(claims.registry.held, isEmpty);
  });

  test('the greeting is empty with no claims, the holds with some', () {
    expect(claims.greeting(), isEmpty);
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    final greeting = claims.greeting().single as DeviceClaimsChanged;
    expect(greeting.holds.single.deviceId, 'd');
  });

  test('flutter run asks the same registry: null, or the busy sentence', () {
    expect(
      claims.claim(deviceId: 'd', sessionId: 's1', verb: 'flutter run'),
      isNull,
    );
    final busy = claims.claim(
      deviceId: 'd',
      sessionId: 's2',
      verb: 'flutter run',
    );
    expect(busy, contains('being driven by another agent'));
    expect(busy, contains('Fix login'));
  });

  test('a subscribing client is greeted with the claims standing', () {
    harness.service.greeters.add(claims.greeting);
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    final received = <DataChanges>[];
    final link = harness.service.open(received.add);
    addTearDown(link.close);
    link.handle(const DataSubscribe());
    final greeted = [
      for (final batch in received) ...batch.changes,
    ].whereType<DeviceClaimsChanged>();
    expect(greeted.single.holds.single.holderSessionId, 's1');
  });

  test('the server\'s watchers hear every batch it tells', () async {
    harness.service.watchers.add(claims.watch);
    claims.claim(deviceId: 'd', sessionId: 's1', verb: 'device_tap');
    harness.service.announce([
      SessionRowChanged(row('s1', SessionStatus.failed)),
    ]);
    await pumpEventQueue();
    expect(claims.registry.held, isEmpty);
  });
}
