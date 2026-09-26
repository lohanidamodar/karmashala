import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// Paired devices at the server: a person's rename, grant and revoke, the
/// companion's own writes told, and **no key, generation or push token in
/// any answer or change**.
void main() {
  late AppDatabase db;
  late PairedDeviceDao devices;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  late int applied;
  final key = Uint8List.fromList(List.filled(32, 0xab));
  const token = 'push-token-that-must-not-travel';

  setUp(() {
    db = AppDatabase.memory();
    devices = PairedDeviceDao(db);
    service = DataService(db);
    applied = 0;
    service.onDevicesWritten = () => applied++;
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    devices
      ..insert(
        PairedDevice(
          id: 'aa11',
          name: 'Pixel',
          deviceKey: key,
          capabilities: CapabilitySet.all,
          generation: 7,
          createdAt: DateTime.utc(2026, 9, 1),
          relayUrl: kLocalRelayMarker,
        ),
      )
      ..updatePush('aa11', token: token, platform: 'fcm');
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  String wire(Object? json) => jsonEncode(json);

  test('the list carries no secret', () {
    final reply = app.handle(const DevicesList());
    expect(reply.value.single.id, 'aa11');
    expect(reply.value.single.deviceKey, isEmpty);
    expect(reply.value.single.pushToken, isNull);
    final json = wire(const DevicesList().resultToJson(reply.value));
    expect(json, isNot(contains(token)));
    expect(json, isNot(contains('abab')));
    expect(json, isNot(contains('generation')));
    expect(json, contains(kLocalRelayMarker));
  });

  test('a rename is trimmed, told and applied; a blank one refused', () {
    final reply = app.handle(const DeviceRename('aa11', '  Work phone '));
    expect(reply.value.name, 'Work phone');
    expect(devices.getById('aa11')!.name, 'Work phone');
    expect(applied, 1);
    final change = told.single.changes.single as DeviceChanged;
    expect(change.device.name, 'Work phone');
    expect(wire(told.single.toJson()), isNot(contains(token)));
    expect(
      () => app.handle(const DeviceRename('aa11', '  ')),
      refused(DataRefusalCode.invalid),
    );
    expect(
      () => app.handle(const DeviceRename('zz', 'x')),
      refused(DataRefusalCode.notFound),
    );
  });

  test('a grant changes what it may do, keeping its key', () {
    final less = CapabilitySet.of([Capability.values.first]);
    final reply = app.handle(DeviceGrant('aa11', less));
    expect(reply.value.capabilities.bits, less.bits);
    expect(devices.getById('aa11')!.deviceKey, key);
    expect(applied, 1);
  });

  test('a revoke deletes the key; a revoked device is granted nothing', () {
    final reply = app.handle(const DeviceRevoke('aa11'));
    expect(reply.value.revoked, isTrue);
    expect(devices.getById('aa11')!.deviceKey, isEmpty);
    expect((told.single.changes.single as DeviceChanged).device.revoked, true);
    expect(
      () => app.handle(DeviceGrant('aa11', CapabilitySet.all)),
      refused(DataRefusalCode.invalid, 'revoked'),
    );
  });

  test("the companion's own writes are told without secrets", () {
    devices.updateLastSeen('aa11', DateTime.utc(2026, 9, 27));
    service.announceDevices();
    final change = told.single.changes.single as DeviceChanged;
    expect(change.device.lastSeenAt, DateTime.utc(2026, 9, 27));
    expect(wire(told.single.toJson()), isNot(contains(token)));
    expect(applied, 0);
  });
}
