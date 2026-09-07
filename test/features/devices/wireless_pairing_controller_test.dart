import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala/src/features/devices/application/wireless_pairing_controller.dart';
import 'package:karmashala/src/features/devices/data/adb_service.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/wireless_pairing.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';

import '../../support/fake_command_runner.dart';

const _adbPath = r'C:\sdk\platform-tools\adb.exe';
const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(environmentId: 'windows', path: _adbPath),
);

const _mdnsAvailable = 'mdns daemon version [adb discovery 0.0.0]\n';
const _mdnsDisabled = 'ERROR: mdns discovery disabled\n';
const _pairingRow =
    'karmashala-TESTNAME\t_adb-tls-pairing._tcp\t10.0.0.5:41733\n';
const _connectRow = 'adb-SERIAL-abc\t_adb-tls-connect._tcp\t10.0.0.5:5555\n';
const _pairedOk =
    'Successfully paired to 10.0.0.5:41733 [guid=adb-SERIAL-abc]\n';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// A scripted adb that counts every process the flow would have created.
class _FakeAdb {
  _FakeAdb({
    this.mdnsCheck = _mdnsAvailable,
    List<String>? services,
    this.pair = 'Failed: Wrong password or connection was dropped.\n',
    this.connect = 'connected to 10.0.0.5:5555\n',
    this.connectExit = 0,
  }) : _services = services ?? const [] {
    runner = FakeCommandRunner(responder: _respond);
  }

  late final FakeCommandRunner runner;
  final String mdnsCheck;

  /// One entry per `mdns services` call; the last repeats once the script runs
  /// out, which is what a real listing does.
  final List<String> _services;
  final String pair;
  final String connect;
  final int connectExit;

  int mdnsServiceCalls = 0;

  /// Every adb process the flow asked for, whatever the verb.
  int get spawns => runner.requests.length;

  List<String> get verbs => [
    for (final request in runner.requests) request.arguments.first,
  ];

  CommandRequest requestFor(String verb) =>
      runner.requests.firstWhere((r) => r.arguments.first == verb);

  CommandResult _respond(CommandRequest request) {
    final verb = request.arguments.join(' ');
    if (verb == 'mdns check') return _ok(mdnsCheck);
    if (verb == 'mdns services') {
      final index = mdnsServiceCalls++;
      if (_services.isEmpty) return _ok('List of discovered mdns services\n');
      return _ok(
        'List of discovered mdns services\n'
        '${_services[index.clamp(0, _services.length - 1)]}',
      );
    }
    if (request.arguments.first == 'pair') {
      return CommandResult(
        exitCode: pair.startsWith('Successfully') ? 0 : 1,
        stdout: pair,
        stderr: '',
      );
    }
    if (request.arguments.first == 'connect') {
      return CommandResult(exitCode: connectExit, stdout: connect, stderr: '');
    }
    return _ok('');
  }
}

/// A container whose adb is [adb] and whose poll costs no wall-clock time.
ProviderContainer _container(_FakeAdb adb, {AndroidSdk? sdk = _sdk}) {
  final container = ProviderContainer(
    overrides: [
      adbServiceProvider.overrideWithValue(
        sdk == null ? null : AdbService(runner: adb.runner, sdk: sdk),
      ),
      mdnsPollIntervalProvider.overrideWithValue(Duration.zero),
      // The name this puts in the QR is the one the fake advertises back.
      pairingInviteFactoryProvider.overrideWithValue(
        () => const AdbPairingInvite(
          serviceName: 'karmashala-TESTNAME',
          password: 'secretpassword',
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The controller, with a listener held the way an open dialog holds one —
/// without it the auto-disposed provider would go while the flow ran.
({WirelessPairingController controller, ProviderSubscription<Object?> sub})
_open(ProviderContainer container) {
  final sub = container.listen<WirelessPairingState>(
    wirelessPairingProvider,
    (_, _) {},
  );
  addTearDown(sub.close);
  return (
    controller: container.read(wirelessPairingProvider.notifier),
    sub: sub,
  );
}

WirelessPairingState _state(ProviderContainer container) =>
    container.read(wirelessPairingProvider);

void main() {
  group('showing a QR code', () {
    test('checks mDNS once, then watches for the name it put in the QR', () async {
      final adb = _FakeAdb(services: [_pairingRow, _connectRow]);
      final container = _container(adb);

      await _open(container).controller.showQrCode();

      expect(adb.runner.requests[0].arguments, ['mdns', 'check']);
      expect(adb.runner.requests[1].arguments, ['mdns', 'services']);
    });

    test('pairs against the pairing port, never the connect port', () async {
      final adb = _FakeAdb(
        services: ['$_pairingRow$_connectRow'],
        pair: _pairedOk,
      );
      final container = _container(adb);

      await _open(container).controller.showQrCode();

      expect(adb.requestFor('pair').arguments[1], '10.0.0.5:41733');
      expect(
        adb.requestFor('connect').arguments[1],
        '10.0.0.5:5555',
        reason: 'the connect port is not the pairing port',
      );
    });

    test('the password in the QR is the code adb is given', () async {
      final adb = _FakeAdb(
        services: ['$_pairingRow$_connectRow'],
        pair: _pairedOk,
      );
      final container = _container(adb);

      await _open(container).controller.showQrCode();

      expect(adb.requestFor('pair').arguments[2], 'secretpassword');
    });

    test('a whole pairing costs five adb processes', () async {
      final adb = _FakeAdb(
        services: ['$_pairingRow$_connectRow'],
        pair: _pairedOk,
      );
      final container = _container(adb);

      await _open(container).controller.showQrCode();

      expect(_state(container), isA<WirelessPairingConnected>());
      expect(adb.spawns, 5, reason: 'check, scan, pair, scan, connect');
    });

    test('a phone that never appears costs the budget and one check', () async {
      final adb = _FakeAdb();
      final container = _container(adb);

      await _open(container).controller.showQrCode();

      expect(adb.mdnsServiceCalls, kMdnsPollBudget);
      expect(adb.spawns, kMdnsPollBudget + 1);
      final state = _state(container);
      expect(state, isA<WirelessPairingFailed>());
      expect((state as WirelessPairingFailed).message, contains('No phone'));
    });

    test('mDNS switched off is said plainly, and costs one process', () async {
      final adb = _FakeAdb(mdnsCheck: _mdnsDisabled);
      final container = _container(adb);

      await _open(container).controller.showQrCode();

      expect(adb.spawns, 1, reason: 'nothing to watch, so nothing is watched');
      final failed = _state(container) as WirelessPairingFailed;
      expect(failed.message, contains('switched off'));
      expect(
        failed.message,
        contains('pairing code'),
        reason: 'the other method still works, so say so',
      );
    });

    test('an unreadable mDNS check is not reported as switched off', () async {
      final adb = _FakeAdb(mdnsCheck: 'who knows\n');
      final container = _container(adb);

      await _open(container).controller.showQrCode();

      final failed = _state(container) as WirelessPairingFailed;
      expect(failed.message, contains('could not be checked'));
      expect(failed.message, isNot(contains('switched off')));
    });

    test('with no SDK it says there is no adb, and spawns nothing', () async {
      final adb = _FakeAdb();
      final container = _container(adb, sdk: null);

      await _open(container).controller.showQrCode();

      expect(adb.spawns, 0);
      expect(
        (_state(container) as WirelessPairingFailed).message,
        contains('No Android SDK'),
      );
    });

    test('the state carries the invite so the QR can be drawn', () async {
      final adb = _FakeAdb();
      final container = _container(adb);
      final open = _open(container);

      final pairing = open.controller.showQrCode();
      await Future<void>.delayed(Duration.zero);
      final state = _state(container);
      expect(state, isA<WirelessPairingWatching>());
      expect(
        (state as WirelessPairingWatching).invite.encode(),
        'WIFI:T:ADB;S:karmashala-TESTNAME;P:secretpassword;;',
      );
      open.controller.cancel();
      await pairing;
    });
  });

  group('the poll stops when nobody is looking', () {
    test('cancelling ends it', () async {
      final adb = _FakeAdb();
      final container = _container(adb);
      final open = _open(container);

      final pairing = open.controller.showQrCode();
      await Future<void>.delayed(Duration.zero);
      open.controller.cancel();
      await pairing;

      final spent = adb.mdnsServiceCalls;
      await Future<void>.delayed(Duration.zero);
      expect(adb.mdnsServiceCalls, spent);
      expect(spent, lessThan(kMdnsPollBudget));
      expect(_state(container), isA<WirelessPairingIdle>());
    });

    test('the dialog going away ends it', () async {
      final adb = _FakeAdb();
      final container = _container(adb);
      final open = _open(container);

      unawaited(open.controller.showQrCode());
      await Future<void>.delayed(Duration.zero);
      // What an unmounted pane does: the last listener goes, and with it the
      // auto-disposed controller.
      open.sub.close();
      await Future<void>.delayed(Duration.zero);

      final spent = adb.mdnsServiceCalls;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        adb.mdnsServiceCalls,
        spent,
        reason: 'an unmounted dialog must not keep spawning adb',
      );
      expect(spent, lessThan(kMdnsPollBudget));
    });
  });

  group('pairing with a code typed by hand', () {
    test('pairs, finds the connect port, connects — three processes', () async {
      final adb = _FakeAdb(services: [_connectRow], pair: _pairedOk);
      final container = _container(adb);

      await _open(container).controller.pairWithCode(
        address: '10.0.0.5:41733',
        code: '123456',
      );

      expect(adb.verbs, ['pair', 'mdns', 'connect']);
      expect(adb.spawns, 3);
      expect(_state(container), isA<WirelessPairingConnected>());
    });

    test('a wrong code says so and spends nothing on connecting', () async {
      final adb = _FakeAdb(services: [_connectRow]);
      final container = _container(adb);

      await _open(container).controller.pairWithCode(
        address: '10.0.0.5:41733',
        code: '123456',
      );

      expect(adb.verbs, ['pair']);
      final failed = _state(container) as WirelessPairingFailed;
      expect(failed.message, contains('pairing code'));
    });

    test('a malformed address is refused before adb is spawned', () async {
      final adb = _FakeAdb();
      final container = _container(adb);

      await _open(container).controller.pairWithCode(
        address: '10.0.0.5',
        code: '123456',
      );

      expect(adb.spawns, 0);
      expect(
        (_state(container) as WirelessPairingFailed).message,
        contains('port'),
      );
    });

    test('a code of the wrong shape is refused before adb is spawned', () async {
      final adb = _FakeAdb();
      final container = _container(adb);

      await _open(container).controller.pairWithCode(
        address: '10.0.0.5:41733',
        code: '12345',
      );

      expect(adb.spawns, 0);
      expect(
        (_state(container) as WirelessPairingFailed).message,
        contains('six digits'),
      );
    });

    test('paired but never advertised: it asks for the port, keeping the pair', () async {
      final adb = _FakeAdb(pair: _pairedOk);
      final container = _container(adb);

      await _open(container).controller.pairWithCode(
        address: '10.0.0.5:41733',
        code: '123456',
      );

      final paired = _state(container) as WirelessPairingPaired;
      expect(paired.host, '10.0.0.5');
      expect(paired.message, contains('IP address & Port'));
      expect(
        adb.mdnsServiceCalls,
        kConnectDiscoveryBudget,
        reason: 'the search for the connect service is bounded too',
      );
    });

    test('mDNS off after a pair costs one scan, not the whole budget', () async {
      final adb = _FakeAdb(pair: _pairedOk);
      final container = _container(adb);
      adb.runner.responder = (request) {
        if (request.arguments.first == 'pair') {
          return _ok(_pairedOk);
        }
        if (request.arguments.join(' ') == 'mdns services') {
          adb.mdnsServiceCalls++;
          return _ok(_mdnsDisabled);
        }
        return _ok('');
      };

      await _open(container).controller.pairWithCode(
        address: '10.0.0.5:41733',
        code: '123456',
      );

      expect(adb.mdnsServiceCalls, 1);
      expect(_state(container), isA<WirelessPairingPaired>());
    });

    test('a refused connection names the port it used', () async {
      final adb = _FakeAdb(
        services: [_connectRow],
        pair: _pairedOk,
        connect: 'failed to connect to 10.0.0.5:5555\n',
        connectExit: 1,
      );
      final container = _container(adb);

      await _open(container).controller.pairWithCode(
        address: '10.0.0.5:41733',
        code: '123456',
      );

      final paired = _state(container) as WirelessPairingPaired;
      expect(paired.message, contains('10.0.0.5:5555'));
    });
  });

  group('connecting to an address the user read off the phone', () {
    test('one process, and the phone is connected', () async {
      final adb = _FakeAdb();
      final container = _container(adb);

      await _open(container).controller.connectTo('10.0.0.5:5555');

      expect(adb.verbs, ['connect']);
      expect(_state(container), isA<WirelessPairingConnected>());
    });

    test('a malformed address spawns nothing', () async {
      final adb = _FakeAdb();
      final container = _container(adb);

      await _open(container).controller.connectTo('nonsense');

      expect(adb.spawns, 0);
      expect(_state(container), isA<WirelessPairingFailed>());
    });
  });

  group('the paired phone joins the normal device list', () {
    test('a connection refreshes the list rather than keeping its own', () async {
      final adb = _FakeAdb(services: [_connectRow], pair: _pairedOk);
      final container = _container(adb);
      final open = _open(container);

      // Something is watching the list, the way the pane does.
      final devices = container.listen(devicesProvider, (_, _) {});
      addTearDown(devices.close);
      await container.read(devicesProvider.future);
      final before = adb.verbs.where((v) => v == 'devices').length;

      await open.controller.pairWithCode(
        address: '10.0.0.5:41733',
        code: '123456',
      );
      await container.read(devicesProvider.future);

      expect(
        adb.verbs.where((v) => v == 'devices').length,
        greaterThan(before),
      );
    });
  });
}
