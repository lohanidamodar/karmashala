import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/ssh/application/companion_route_store.dart';
import 'package:karmashala/src/features/ssh/application/ssh_terminal_opener.dart';
import 'package:karmashala/src/features/ssh/presentation/pair_phone_dialog.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SshBoxAnswer, SshDeployAction;
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What the server answers about a box, for the two questions the dialog
/// asks it (`ssh.companionEndpoint`, `ssh.pairPhone`, slice 5d), and how it
/// was asked them.
class _Setup {
  _Setup(
    this.host, {
    required this.reachable,
    this.ttl = const Duration(minutes: 5),
    this.privileged,
  });

  final SshHost host;
  bool reachable;
  final Duration ttl;

  /// The firewall step a shut port is answered with — until it was run by hand.
  final PrivilegedCommand? privileged;

  /// Whether each dial was a check after that step.
  final byHand = <bool>[];

  /// The relay each pairing window was opened with; empty is the direct route.
  final relays = <String>[];
  int dials = 0;

  CompanionEndpoint prepare({bool ruleAddedByHand = false}) {
    dials++;
    byHand.add(ruleAddedByHand);
    final step = ruleAddedByHand ? null : privileged;
    return CompanionEndpoint(
      address: host.host,
      port: 47820,
      hostName: host.name,
      reachable: reachable,
      reason: reachable
          ? '${host.host}:47820 answered.'
          : step != null
          ? 'ufw is running on ${host.host} and `sudo` there asks for a '
                'password, so 47820/tcp was not opened.'
          : '${host.host}:47820 still does not answer — a provider firewall '
                'is the usual one.',
      command: step?.command,
      privileged: step,
      outsideTheMachine: !reachable && step == null,
    );
  }

  PairingWindow openWindow({required int capabilities, String relay = ''}) {
    relays.add(relay);
    return PairingWindow(
      status: PairingRequestStatus.open,
      observedAt: testTime,
      reason: 'Open.',
      // A different, valid code per window, so a stale QR would be caught.
      code: PairingCode.encode(List<int>.filled(20, relays.length)),
      expiresAt: testTime.add(ttl),
    );
  }

}

void main() {
  final host = SshHost(
    id: 'h1',
    name: 'do-box',
    host: '203.0.113.9',
    port: 22,
    username: 'dlohani',
    authMethod: SshAuthMethod.password,
    createdAt: testTime,
  );

  late FakeDataServer server;
  late DataClient data;
  setUp(() async {
    server = FakeDataServer(clock: () => testTime);
    data = await server.connect();
  });

  /// Not `pumpAndSettle`: the busy line spins, and the expiry timer is real.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  final terminals = <({String host, String? typed})>[];
  setUp(terminals.clear);

  /// The deploy the server answers with instead, until a client installs.
  HostDeployment? notDeployed;
  setUp(() => notDeployed = null);

  void serve(_Setup setup) {
    bool installed() => server.sshWork.deploys.any(
      (d) => d.action == SshDeployAction.install,
    );
    server.sshWork.onEndpoint = (request) => notDeployed != null && !installed()
        ? SshBoxAnswer.notDeployed(notDeployed!)
        : SshBoxAnswer.of(
            setup.prepare(ruleAddedByHand: request.ruleAddedByHand),
          );
    server.sshWork.onPair = (request) => SshBoxAnswer.of(
      setup.openWindow(
        capabilities: request.capabilities,
        relay: request.relay,
      ),
    );
  }

  Future<void> open(WidgetTester tester, _Setup setup) async {
    serve(setup);
    // Tall enough that nothing the tests tap is scrolled out of the dialog.
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // A scope per open: the family provider keeps the setup it built, and a
        // second open in one test is a second launch with its own box.
        key: UniqueKey(),
        overrides: [
          dataClientProvider.overrideWithValue(data),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          sshTerminalOpenerProvider.overrideWithValue((host, {typed}) {
            terminals.add((host: host.name, typed: typed));
            return true;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => PairPhoneDialog.show(context, host: host),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
  }

  /// What the drawn QR says, or null while none is drawn.
  HostPairingInvite? drawnInvite(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter is QrPainter) {
        return HostPairingInvite.decode(painter.data, now: testTime);
      }
    }
    return null;
  }

  SegmentedButton<HostRoute> routeButton(WidgetTester tester) =>
      tester.widget(find.byType(SegmentedButton<HostRoute>));

  group('a machine with no session host to pair with', () {
    testWidgets('says why and what to do, and its button installs and carries '
        'on to a code', (tester) async {
      final setup = _Setup(host, reachable: true);
      notDeployed = HostDeployment(
        status: HostDeploymentStatus.cannotInstall,
        observedAt: testTime.subtract(const Duration(minutes: 1)),
        reason: 'Could not write the bundle on do-box.',
      );
      await open(tester, setup);

      expect(find.textContaining('Bad state'), findsNothing);
      expect(find.textContaining('No session host is deployed'), findsNothing);
      expect(find.textContaining('Could not write the bundle'), findsOneWidget);
      expect(find.textContaining('no root is needed'), findsOneWidget);
      expect(setup.relays, isEmpty, reason: 'no code was asked for');

      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await tester.runAsync(pumpEventQueue);
      await settle(tester);

      expect(server.sshWork.deploys.last.action, SshDeployAction.install);
      expect(setup.relays, [''], reason: 'installed, so the code is fetched');
      expect(find.text('Code'), findsOneWidget);
    });
  });

  group('a firewall that wants a password', () {
    const step = PrivilegedCommand(
      command: 'sudo ufw allow 47820/tcp',
      does: 'Allows inbound TCP 47820 through ufw on 203.0.113.9.',
      why:
          '`sudo` on 203.0.113.9 asks for a password, and Karmashala never '
          'asks for one.',
    );

    testWidgets('the command is offered to a terminal, typed and not run', (
      tester,
    ) async {
      final setup = _Setup(host, reachable: false, privileged: step);
      await open(tester, setup);

      expect(find.text(step.command), findsOneWidget);
      expect(find.textContaining('never asks for one'), findsOneWidget);

      await tester.tap(find.text('Open a terminal on do-box'));
      await tester.pumpAndSettle();

      expect(terminals, [(host: 'do-box', typed: step.command)]);
      expect(terminals.single.typed!.endsWith('\n'), isFalse);
      expect(find.text('Pair a phone with do-box'), findsNothing);
    });

    testWidgets('"Check again" dials again, and finds the port open', (
      tester,
    ) async {
      final setup = _Setup(host, reachable: false, privileged: step);
      await open(tester, setup);
      setup.reachable = true;

      await tester.tap(find.text('Check again'));
      await settle(tester);

      expect(setup.byHand, [false, true]);
      expect(find.text(step.command), findsNothing);
      expect(find.textContaining('47820 answered'), findsOneWidget);
    });

    testWidgets('reopened after the terminal step, a port still shut is the '
        'provider\'s and the command is not offered again', (tester) async {
      final setup = _Setup(host, reachable: false, privileged: step);
      await open(tester, setup);
      await tester.tap(find.text('Open a terminal on do-box'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open'));
      await settle(tester);

      expect(setup.byHand, [false, true]);
      expect(find.text(step.command), findsNothing);
      expect(find.textContaining('provider firewall'), findsOneWidget);
    });
  });

  group('the route', () {
    testWidgets('a box that answered is reached at itself', (tester) async {
      final setup = _Setup(host, reachable: true);
      await open(tester, setup);

      expect(routeButton(tester).selected, {HostRoute.direct});
      expect(setup.relays, [
        '',
      ], reason: 'direct asks the host to dial nothing');
      expect(find.textContaining('Nothing else is involved'), findsOneWidget);
    });

    testWidgets(
      'one that did not is met at the hosted relay, with the reason',
      (tester) async {
        final setup = _Setup(host, reachable: false);
        await open(tester, setup);

        expect(routeButton(tester).selected, {HostRoute.relay});
        // The desktop's own hosted relay — one definition, not a second copy.
        expect(setup.relays, [kDefaultRelayUrl]);
        expect(find.textContaining('still does not answer'), findsOneWidget);
        expect(find.textContaining('sees both addresses'), findsOneWidget);
      },
    );

    testWidgets('a choice is kept for that host and outranks the dial', (
      tester,
    ) async {
      final setup = _Setup(host, reachable: true);
      await open(tester, setup);

      await tester.tap(find.text('Hosted relay'));
      await settle(tester);

      expect(CompanionRouteStore(server.store).read('h1'), HostRoute.relay);
      expect(setup.relays, ['', kDefaultRelayUrl]);
      expect(
        setup.dials,
        1,
        reason: 'a route change is not a reason to re-dial',
      );

      // Closed and opened again: reachable, and still the relay.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final again = _Setup(host, reachable: true);
      await open(tester, again);
      expect(routeButton(tester).selected, {HostRoute.relay});
      expect(again.relays, [kDefaultRelayUrl]);
    });

    test('nothing chosen means the dial decides', () {
      expect(routeFor(chosen: null, reachable: true), HostRoute.direct);
      expect(routeFor(chosen: null, reachable: false), HostRoute.relay);
      expect(
        routeFor(chosen: HostRoute.direct, reachable: false),
        HostRoute.direct,
      );
    });
  });

  group('the QR', () {
    testWidgets('is not drawn until it is asked for', (tester) async {
      await open(tester, _Setup(host, reachable: true));

      expect(drawnInvite(tester), isNull);
      await tester.tap(find.text('Show QR'));
      await tester.pump();

      final invite = drawnInvite(tester)!;
      expect(invite.endpoint, '203.0.113.9:47820');
      expect(invite.hostName, 'do-box');
      expect(invite.route, HostRoute.direct);
      expect(invite.relay, isNull);
      expect(invite.code, PairingCode.encode(List<int>.filled(20, 1)));
      expect(invite.expiresAt, testTime.add(const Duration(minutes: 5)));

      await tester.tap(find.text('Hide QR'));
      await tester.pump();
      expect(drawnInvite(tester), isNull);
    });

    testWidgets('carries the relay on the relay route, and can be pasted', (
      tester,
    ) async {
      await open(tester, _Setup(host, reachable: false));
      await tester.tap(find.text('Show QR'));
      await tester.pump();

      final invite = drawnInvite(tester)!;
      expect(invite.route, HostRoute.relay);
      expect(invite.relay, Uri.parse(kDefaultRelayUrl));

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await tester.ensureVisible(find.text('Copy pairing link'));
      await tester.tap(find.text('Copy pairing link'));
      await tester.pump();
      expect(
        HostPairingInvite.decode(copied!, now: testTime).relay,
        Uri.parse(kDefaultRelayUrl),
      );
    });

    testWidgets('does not outlive its code: a new one comes back hidden', (
      tester,
    ) async {
      final setup = _Setup(
        host,
        reachable: true,
        ttl: const Duration(minutes: 1),
      );
      await open(tester, setup);
      await tester.tap(find.text('Show QR'));
      await tester.pump();
      final first = drawnInvite(tester)!.code;

      await tester.pump(const Duration(minutes: 1, seconds: 1));
      await settle(tester);

      expect(drawnInvite(tester), isNull, reason: 'hidden again');
      expect(setup.relays, hasLength(2), reason: 'a fresh window was opened');
      await tester.tap(find.text('Show QR'));
      await tester.pump();
      expect(drawnInvite(tester)!.code, isNot(first));
    });

    testWidgets('a dialog left open stops asking the host for codes', (
      tester,
    ) async {
      final setup = _Setup(
        host,
        reachable: true,
        ttl: const Duration(minutes: 1),
      );
      await open(tester, setup);

      for (var i = 0; i < PairPhoneDialog.maxAutoRenewals + 2; i++) {
        await tester.pump(const Duration(minutes: 1, seconds: 1));
        await settle(tester);
      }

      expect(setup.relays, hasLength(1 + PairPhoneDialog.maxAutoRenewals));
      expect(find.textContaining('The code expired'), findsOneWidget);
      expect(drawnInvite(tester), isNull);
      expect(find.text('Show QR'), findsNothing);

      // Asking by hand starts the count again.
      await tester.tap(find.text('New code'));
      await settle(tester);
      expect(find.text('Show QR'), findsOneWidget);
    });

    testWidgets('an address only this computer understands gets no QR', (
      tester,
    ) async {
      final local = SshHost(
        id: 'h2',
        name: 'wsl-sshd',
        host: '127.0.0.1',
        port: 2222,
        username: 'me',
        authMethod: SshAuthMethod.password,
        createdAt: testTime,
      );
      serve(_Setup(local, reachable: true));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dataClientProvider.overrideWithValue(data),
            clockProvider.overrideWithValue(FixedClock(testTime)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => PairPhoneDialog.show(context, host: local),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await settle(tester);

      expect(find.text('Show QR'), findsNothing);
      expect(find.textContaining('No QR for this one'), findsOneWidget);
      // The values are still there for whoever knows what they are doing.
      expect(find.text('127.0.0.1:47820'), findsOneWidget);
    });
  });
}
