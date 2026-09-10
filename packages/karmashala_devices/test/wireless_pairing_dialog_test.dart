import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/dialogs.dart';

import 'support/fake_command_runner.dart';

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

const _mdnsAvailable = 'mdns daemon version [adb discovery 0.0.0]\n';
const _pairingRow =
    'karmashala-TESTNAME\t_adb-tls-pairing._tcp\t10.0.0.5:41733\n';
const _connectRow = 'adb-SERIAL-abc\t_adb-tls-connect._tcp\t10.0.0.5:5555\n';
const _pairedOk =
    'Successfully paired to 10.0.0.5:41733 [guid=adb-SERIAL-abc]\n';

/// One fake-time step. The poll interval is a millisecond here, so a handful of
/// these covers a whole budget without any real waiting.
const _step = Duration(milliseconds: 2);

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// A scripted adb. [advertising] is what `mdns services` lists, so a test can
/// hold the phone back or hand it over.
class _FakeAdb {
  _FakeAdb({this.advertising = '', this.pair = _pairedOk}) {
    runner = FakeCommandRunner(responder: _respond);
  }

  late final FakeCommandRunner runner;
  String advertising;
  String pair;

  int get spawns => runner.requests.length;
  int mdnsServiceCalls = 0;

  CommandResult _respond(CommandRequest request) {
    final verb = request.arguments.join(' ');
    if (verb == 'mdns check') return _ok(_mdnsAvailable);
    if (verb == 'mdns services') {
      mdnsServiceCalls++;
      return _ok('List of discovered mdns services\n$advertising');
    }
    if (request.arguments.first == 'pair') {
      return CommandResult(
        exitCode: pair.startsWith('Successfully') ? 0 : 1,
        stdout: pair,
        stderr: '',
      );
    }
    if (request.arguments.first == 'connect') {
      return _ok('connected to 10.0.0.5:5555\n');
    }
    return _ok('');
  }
}

/// Advances fake time in small steps so the poll can run. Deliberately a
/// **count** of steps: a bounded loop is what is being exercised, and this
/// cannot outrun it.
Future<void> _settle(WidgetTester tester, {int steps = 90}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(_step);
  }
}

Future<void> _pumpDialog(
  WidgetTester tester,
  _FakeAdb adb, {
  Size size = _desktop,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adbServiceProvider.overrideWithValue(
          AdbService(runner: adb.runner, sdk: _sdk),
        ),
        devicesProvider.overrideWith((ref) async => const <AndroidDevice>[]),
        mdnsPollIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 1),
        ),
        pairingInviteFactoryProvider.overrideWithValue(
          () => const AdbPairingInvite(
            serviceName: 'karmashala-TESTNAME',
            password: 'secretpassword',
          ),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: _DialogHost())),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
  await _settle(tester, steps: 4);
}

/// Cancels whatever is running and takes the dialog down — the route a user
/// closing it takes, and what leaves no armed timer behind.
Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.text('Cancel'));
  await tester.pumpAndSettle();
}

/// A button that opens the dialog, so the test drives the same route a user
/// does: a dialog pushed onto a navigator rather than pumped bare.
class _DialogHost extends StatelessWidget {
  const _DialogHost();

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => WirelessPairingDialog.show(context),
    child: const Text('Open'),
  );
}

Future<void> _chooseTypedMethod(WidgetTester tester) async {
  await tester.tap(find.text('Pairing code'));
  await tester.pumpAndSettle();
}

Future<void> _submit(
  WidgetTester tester, {
  String address = '10.0.0.5:41733',
  String code = '123456',
}) async {
  await tester.enterText(
    find.byKey(const Key('wireless-pairing-address')),
    address,
  );
  await tester.enterText(find.byKey(const Key('wireless-pairing-code')), code);
  await tester.tap(find.byKey(const Key('wireless-pairing-submit')));
  await tester.pump();
}

void main() {
  group('the QR half', () {
    testWidgets('draws the invite it generated, and gives the wait an end', (
      tester,
    ) async {
      final adb = _FakeAdb();
      await _pumpDialog(tester, adb);

      final painter = tester
          .widget<CustomPaint>(find.byKey(const Key('wireless-pairing-qr')))
          .painter;
      expect(painter, isA<QrPainter>());
      expect(find.textContaining('checks left'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('the phone appearing carries it through to connected', (
      tester,
    ) async {
      final adb = _FakeAdb(advertising: '$_pairingRow$_connectRow');
      await _pumpDialog(tester, adb);
      await _settle(tester, steps: 10);

      expect(find.textContaining('Connected to 10.0.0.5:5555'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('closing the dialog stops the watch', (tester) async {
      final adb = _FakeAdb();
      await _pumpDialog(tester, adb);
      await _settle(tester, steps: 10);
      expect(adb.mdnsServiceCalls, greaterThan(0));

      await _close(tester);
      final spent = adb.mdnsServiceCalls;
      await _settle(tester, steps: 20);

      expect(
        adb.mdnsServiceCalls,
        spent,
        reason: 'an unmounted dialog must not keep spawning adb',
      );
    });

    testWidgets('the budget running out says what to check, and offers a retry', (
      tester,
    ) async {
      final adb = _FakeAdb();
      await _pumpDialog(tester, adb);
      await _settle(tester, steps: 200);

      expect(adb.mdnsServiceCalls, kMdnsPollBudget);
      expect(find.textContaining('No phone advertised itself'), findsOneWidget);
      expect(find.byKey(const Key('wireless-pairing-retry')), findsOneWidget);
      expect(find.byKey(const Key('wireless-pairing-qr')), findsNothing);
    });
  });

  group('the typed half', () {
    testWidgets('switching to it ends the QR watch and shows the form', (
      tester,
    ) async {
      final adb = _FakeAdb();
      await _pumpDialog(tester, adb);
      await _settle(tester, steps: 10);

      await _chooseTypedMethod(tester);
      final spent = adb.mdnsServiceCalls;
      await _settle(tester, steps: 30);

      expect(adb.mdnsServiceCalls, spent);
      expect(find.byKey(const Key('wireless-pairing-qr')), findsNothing);
      expect(find.byKey(const Key('wireless-pairing-address')), findsOneWidget);
      expect(find.byKey(const Key('wireless-pairing-code')), findsOneWidget);
      await _close(tester);
    });

    testWidgets('a short code is refused before adb is spawned', (
      tester,
    ) async {
      final adb = _FakeAdb();
      await _pumpDialog(tester, adb);
      await _chooseTypedMethod(tester);
      final before = adb.spawns;

      await _submit(tester, code: '12345');
      await tester.pumpAndSettle();

      expect(adb.spawns, before);
      expect(find.textContaining('six digits'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('a good code pairs and connects', (tester) async {
      final adb = _FakeAdb(advertising: _connectRow);
      await _pumpDialog(tester, adb);
      await _chooseTypedMethod(tester);

      await _submit(tester);
      await _settle(tester, steps: 10);

      expect(find.textContaining('Connected to 10.0.0.5:5555'), findsOneWidget);
    });

    testWidgets('paired without a port asks for one, prefilled with the host', (
      tester,
    ) async {
      final adb = _FakeAdb();
      await _pumpDialog(tester, adb);
      await _chooseTypedMethod(tester);

      await _submit(tester);
      await _settle(tester, steps: 40);

      expect(find.textContaining('IP address & Port'), findsWidgets);
      final field = tester.widget<TextField>(
        find.byKey(const Key('wireless-pairing-connect-address')),
      );
      expect(field.controller?.text, '10.0.0.5:');
      expect(find.byKey(const Key('wireless-pairing-connect')), findsOneWidget);
      await _close(tester);
    });

    testWidgets('a wrong code says the code was wrong, and stays on the form', (
      tester,
    ) async {
      final adb = _FakeAdb(
        pair: 'Failed: Wrong password or connection was dropped.\n',
      );
      await _pumpDialog(tester, adb);
      await _chooseTypedMethod(tester);

      await _submit(tester);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('pairing code was not accepted'),
        findsOneWidget,
      );
      // The retry button belongs to the QR half; here the form itself is how
      // you try again.
      expect(find.byKey(const Key('wireless-pairing-retry')), findsNothing);
      expect(find.byKey(const Key('wireless-pairing-submit')), findsOneWidget);
      await _close(tester);
    });
  });

  group('at both window sizes', () {
    for (final (name, size) in const [
      ('phone', _phone),
      ('desktop', _desktop),
    ]) {
      testWidgets('the QR half lays out on a $name window', (tester) async {
        final adb = _FakeAdb();
        await _pumpDialog(tester, adb, size: size);

        expect(find.byKey(const Key('wireless-pairing-qr')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _close(tester);
      });

      testWidgets('the typed half lays out on a $name window', (tester) async {
        final adb = _FakeAdb();
        await _pumpDialog(tester, adb, size: size);
        await _chooseTypedMethod(tester);

        expect(
          find.byKey(const Key('wireless-pairing-address')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await _close(tester);
      });
    }
  });
}
