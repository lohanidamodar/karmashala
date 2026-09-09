/// The Connections surfaces at phone size: the settings list of saved
/// desktops (empty / one / many), the tap that switches, the per-host forget,
/// and the switcher strip above the session list.
library;

import 'dart:async';

import 'package:karmashala/src/app/companion/companion_shell.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/features/companion/application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/presentation/connections_section.dart';
import 'package:karmashala/src/features/companion/presentation/host_switcher_bar.dart';
import 'package:karmashala/src/features/companion/presentation/pairing/pairing_screen.dart';
import 'package:karmashala_remote/remote.dart' show CapabilitySet;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

/// A gateway whose switch fails in a way the switcher has no name for. A
/// keystore that stopped answering throws `TimeoutException`, and every
/// surface that offers this verb shows `lastError` and nothing else.
class _WedgedGateway extends FakeCompanionGateway {
  _WedgedGateway({required super.connections})
    : super(pairing: CompanionPairing(capabilities: CapabilitySet.all));

  @override
  Future<void> switchTo(String hostId) =>
      throw TimeoutException('the keystore never answered');
}

/// A gateway that does **not** honour the seeding the contract asks for: its
/// connections stream stays silent until a test says otherwise.
///
/// The two real gateways seed the stream and emit on listen, so the unknown
/// window is one microtask and no user ever sees it. That is exactly why it
/// needs a test: the section must not fill the silence with a claim, and it
/// must not take its own action away while it waits.
class _SilentConnections extends FakeCompanionGateway {
  _SilentConnections()
    : super(pairing: CompanionPairing(capabilities: CapabilitySet.all));

  final _connectionsController =
      StreamController<List<CompanionConnection>>.broadcast();

  @override
  Stream<List<CompanionConnection>> get connectionsStates =>
      _connectionsController.stream;

  void deliver(List<CompanionConnection> saved) =>
      _connectionsController.add(saved);

  void fail(Object error) => _connectionsController.addError(error);
}

void main() {
  final studio = fakeHostId(1);
  final laptop = fakeHostId(2);

  List<CompanionConnection> twoDesktops({String active = 'studio'}) => [
    CompanionConnection(
      hostId: studio,
      name: 'Studio',
      active: active == 'studio',
      lastConnectedAt: DateTime.now().toUtc().subtract(
        const Duration(hours: 3),
      ),
    ),
    CompanionConnection(
      hostId: laptop,
      name: 'Laptop',
      active: active == 'laptop',
    ),
  ];

  group('the connections section', () {
    testWidgets('one desktop reads as the paired desktop, with no switching '
        'chrome it does not need', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: [
          CompanionConnection(hostId: studio, name: 'Studio', active: true),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      expect(find.text('PAIRED DESKTOP'), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Add a desktop'), findsOneWidget);
    });

    testWidgets('many desktops list with their active badge and last use', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      expect(find.text('DESKTOPS'), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      // Exactly one active badge, and the other says when it was last used.
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Never connected'), findsOneWidget);
    });

    testWidgets('an unpaired phone says so and still offers the way in', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway(),
        home: const ConnectionsSection(),
      );

      expect(find.textContaining('No desktops saved'), findsOneWidget);
      expect(find.text('Add a desktop'), findsOneWidget);
    });

    testWidgets('tapping an inactive desktop switches to it', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
        sessionsByHost: {
          laptop: [summary('s-laptop', title: 'Laptop work')],
        },
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();

      expect(gateway.switchRequests, [laptop]);
      expect(gateway.connections.singleWhere((c) => c.active).name, 'Laptop');
    });

    testWidgets('the active desktop is not a switch target', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      await tester.tap(find.text('Studio'));
      await tester.pumpAndSettle();

      expect(gateway.switchRequests, isEmpty);
    });

    testWidgets('a switch in flight shows progress and blocks a second tap', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
        switchDelay: const Duration(milliseconds: 300),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      await tester.tap(find.text('Laptop'));
      await tester.pump();

      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // A second tap while the first is in flight must not queue another.
      await tester.tap(find.text('Laptop'), warnIfMissed: false);
      await tester.pump();
      expect(gateway.switchRequests, hasLength(1));

      await tester.pumpAndSettle();
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets('forgetting one desktop asks first, then removes only it', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      await tester.tap(find.byTooltip('Forget Laptop'));
      await tester.pumpAndSettle();
      expect(find.text('Forget Laptop?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
      await tester.pumpAndSettle();

      expect([for (final c in gateway.connections) c.name], ['Studio']);
    });

    testWidgets('cancelling the forget dialog keeps the desktop', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      await tester.tap(find.byTooltip('Forget Laptop'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(gateway.connections, hasLength(2));
    });

    testWidgets('"Add a desktop" opens the pairing flow', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      await tester.tap(find.text('Add a desktop'));
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
    });
  });

  group('the switcher strip above the sessions', () {
    testWidgets('one desktop pays no chrome for a choice it does not have', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        connections: [
          CompanionConnection(hostId: studio, name: 'Studio', active: true),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const HostSwitcherBar(),
      );

      expect(find.text('Studio'), findsNothing);
    });

    testWidgets('two desktops name the active one and how many are saved', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const HostSwitcherBar(),
      );

      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('2 saved'), findsOneWidget);
    });

    testWidgets('the sheet switches desktops in one tap', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
        sessionsByHost: {
          laptop: [summary('s-laptop', title: 'Laptop work')],
        },
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const HostSwitcherBar(),
      );

      await tester.tap(find.text('Studio'));
      await tester.pumpAndSettle();
      // The sheet lists both; pick the other one.
      await tester.tap(find.text('Laptop').last);
      await tester.pumpAndSettle();

      expect(gateway.switchRequests, [laptop]);
    });

    testWidgets('the sheet also offers the way to a new desktop', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const HostSwitcherBar(),
      );

      await tester.tap(find.text('Studio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a desktop'));
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
    });
  });

  group('in the shell', () {
    testWidgets('the strip rides above the Sessions tab, and the session '
        'list swaps with the desktop', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [summary('s-studio', title: 'Studio work')],
        connections: twoDesktops(),
        sessionsByHost: {
          laptop: [summary('s-laptop', title: 'Laptop work')],
        },
      );
      await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

      expect(find.byType(HostSwitcherBar), findsOneWidget);
      expect(find.text('Studio work'), findsOneWidget);

      await tester.tap(find.text('Studio').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop').last);
      await tester.pumpAndSettle();

      expect(find.text('Laptop work'), findsOneWidget);
      expect(
        find.text('Studio work'),
        findsNothing,
        reason: "the old desktop's sessions do not linger after a switch",
      );
    });

    testWidgets('the settings tab lists the desktops', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoDesktops(),
      );
      await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('DESKTOPS'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.text('THIS CONNECTION'), findsOneWidget);
    });

    testWidgets('a single-desktop phone shows no strip at all', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [summary('s1')],
        connections: [
          CompanionConnection(hostId: studio, name: 'Studio', active: true),
        ],
      );
      await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

      expect(find.byType(HostSwitcherBar), findsOneWidget);
      expect(find.text('2 saved'), findsNothing);
      expect(find.text('Session s1'), findsOneWidget);
    });
  });

  group('a switch that cannot reach its desktop', () {
    testWidgets('lands on the chosen desktop and says the host is '
        'unreachable — never silently back on the old one', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [summary('s-studio', title: 'Studio work')],
        connections: twoDesktops(),
        failSwitchTo: laptop,
      );
      await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

      await tester.tap(find.text('Studio').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop').last);
      await tester.pumpAndSettle();

      expect(
        gateway.connections.singleWhere((c) => c.active).name,
        'Laptop',
        reason: 'the phone is on the desktop the user chose',
      );
      expect(find.textContaining('Host unreachable'), findsOneWidget);
      expect(find.text('Studio work'), findsNothing);
    });
  });

  test('a refusal the switcher has no name for still leaves the user '
      'something to read', () async {
    final container = ProviderContainer(
      overrides: [
        companionGatewayProvider.overrideWithValue(
          _WedgedGateway(connections: twoDesktops()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final switcher = container.read(companionSwitchingProvider.notifier);
    await switcher.switchTo(laptop);

    expect(
      switcher.lastError,
      isNotNull,
      reason: 'a tap that silently does nothing is the worst outcome here',
    );
    expect(
      container.read(companionSwitchingProvider),
      isNull,
      reason: 'and the switch is over, so the next tap is not swallowed',
    );
  });

  group('before the phone knows what it has saved', () {
    testWidgets('says nothing about how many, and still offers the way in', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _SilentConnections(),
        home: const ConnectionsSection(),
      );

      expect(
        find.textContaining('No desktops saved'),
        findsNothing,
        reason: 'an unanswered read is not the same fact as an empty phone',
      );
      expect(
        find.text('Add a desktop'),
        findsOneWidget,
        reason: 'the section used to collapse, taking its one verb with it',
      );
      expect(find.text('DESKTOPS'), findsOneWidget);
    });

    testWidgets('and says it the moment an empty list arrives', (tester) async {
      final gateway = _SilentConnections();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );
      expect(find.textContaining('No desktops saved'), findsNothing);

      gateway.deliver(const []);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No desktops saved'),
        findsOneWidget,
        reason: 'loading and empty are two states, and this is the second',
      );
      expect(find.text('Add a desktop'), findsOneWidget);
    });

    testWidgets('a list that arrives fills the same slot', (tester) async {
      final gateway = _SilentConnections();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      gateway.deliver(twoDesktops());
      await tester.pumpAndSettle();

      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.textContaining('No desktops saved'), findsNothing);
    });

    testWidgets('a read that fails says so rather than vanishing', (
      tester,
    ) async {
      final gateway = _SilentConnections();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      gateway.fail(const GatewayException('The keystore is locked.'));
      await tester.pumpAndSettle();

      expect(find.text('The keystore is locked.'), findsOneWidget);
      expect(find.textContaining('No desktops saved'), findsNothing);
      expect(find.text('Add a desktop'), findsOneWidget);
    });
  });

  group('at 200% text', () {
    testWidgets('the connections section lists, badges and forgets without '
        'overflowing', (tester) async {
      final gateway = FakeCompanionGateway.paired(connections: twoDesktops());
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
        textScale: 2.0,
      );

      expect(find.text('DESKTOPS'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Add a desktop'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the switcher strip keeps its name, count and caret on one '
        'row', (tester) async {
      final gateway = FakeCompanionGateway.paired(connections: twoDesktops());
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const HostSwitcherBar(),
        textScale: 2.0,
      );

      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('2 saved'), findsOneWidget);
      expect(
        tester.getSize(find.byType(InkWell).first).height,
        greaterThan(Touch.target),
      );
      expect(tester.takeException(), isNull);
    });
  });

}
