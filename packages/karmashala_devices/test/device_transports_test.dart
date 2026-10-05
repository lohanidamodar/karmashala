import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:test/test.dart';

AndroidDevice _device(
  String serial, {
  String? model = 'CPH1989',
  DeviceConnectionState state = DeviceConnectionState.device,
  String environmentId = 'windows',
}) => AndroidDevice(
  serial: serial,
  environmentId: environmentId,
  state: state,
  model: model,
);

const _usb = '2B071FDH300JJ9';
const _mdns = 'adb-2B071FDH300JJ9-zcg43M._adb-tls-connect._tcp';

/// One phone on a cable and on wireless adb is one device, listed once.
void main() {
  test('a wireless transport named by its serial joins the cable', () {
    final merged = mergeDeviceTransports([_device(_usb), _device(_mdns)]);
    expect(merged, hasLength(1));
    expect(merged.single.serial, _usb, reason: 'the cable answers first');
    expect(merged.single.otherSerials, [_mdns]);
    expect(merged.single.answersTo(_mdns), isTrue);
  });

  test('an ip:port transport joins the one cable of its model', () {
    final merged = mergeDeviceTransports([
      _device('192.168.1.20:5555'),
      _device(_usb),
      _device('emulator-5554', model: 'sdk_gphone64_x86_64'),
    ]);
    expect([for (final d in merged) d.serial], [_usb, 'emulator-5554']);
    expect(merged.first.otherSerials, ['192.168.1.20:5555']);
  });

  test('a cable not ready leaves the wireless transport to answer', () {
    final merged = mergeDeviceTransports([
      _device(_usb, state: DeviceConnectionState.unauthorized),
      _device(_mdns),
    ]);
    expect(merged.single.serial, _mdns);
    expect(merged.single.otherSerials, [_usb]);
    expect(merged.single.isReady, isTrue);
  });

  test('two phones of one model on cables are not guessed apart', () {
    final devices = [
      _device(_usb),
      _device('R58M12ABCDE'),
      _device('192.168.1.20:5555'),
    ];
    expect(mergeDeviceTransports(devices), devices);
  });

  test('a different phone, or another adb server, stays its own row', () {
    final devices = [
      _device(_usb),
      _device('adb-R58M12ABCDE-x1._adb-tls-connect._tcp', model: 'SM_G973F'),
      _device(_mdns, environmentId: 'wsl:arch'),
    ];
    expect(mergeDeviceTransports(devices), devices);
  });

  group('with no cable, two wireless transports of one phone', () {
    const ip = '192.168.1.20:38637';
    const mdns = 'adb-QX7TESTSERIAL01-ab12Cd._adb-tls-connect._tcp';

    test('join when adb gives both the same hardware serial', () {
      final merged = mergeDeviceTransports(
        [_device(ip), _device(mdns)],
        hardwareSerials: {ip: 'QX7TESTSERIAL01', mdns: 'QX7TESTSERIAL01'},
      );
      expect(merged, hasLength(1));
      expect(merged.single.serial, ip, reason: 'the direct address answers');
      expect(merged.single.otherSerials, [mdns]);
      expect(merged.single.answersTo(mdns), isTrue);
    });

    test('join on the serial the mDNS name carries when only the ip:port one '
        'was asked', () {
      final merged = mergeDeviceTransports(
        [_device(mdns), _device(ip)],
        hardwareSerials: {ip: 'QX7TESTSERIAL01'},
      );
      expect([for (final d in merged) d.serial], [ip]);
      expect(merged.single.otherSerials, [mdns]);
    });

    test('stay apart when their hardware serials differ', () {
      final devices = [_device(ip), _device(mdns)];
      expect(
        mergeDeviceTransports(
          devices,
          hardwareSerials: {ip: 'OTHERPHONE0002', mdns: 'QX7TESTSERIAL01'},
        ),
        devices,
      );
    });

    test('are not joined on their model alone', () {
      final devices = [_device(ip), _device(mdns)];
      expect(mergeDeviceTransports(devices), devices);
    });
  });
}
