/// The Connections surfaces at phone size: the settings list of saved
/// machines (empty / one / many), the tap that switches, the per-host forget,
/// and the switcher strip above the session list.
library;

import 'dart:async';

import 'package:karmashala/src/app/companion/companion_shell.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_companion/providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_remote/remote.dart' show CapabilitySet;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';

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

  List<CompanionConnection> twoMachines({String active = 'studio'}) => [
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
    testWidgets('one machine reads as the paired machine, with no switching '
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

      expect(find.text('PAIRED MACHINE'), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Add a machine'), findsOneWidget);
    });

    testWidgets('many machines list with their active badge and last use', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      expect(find.text('MACHINES'), findsOneWidget);
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

      expect(find.textContaining('No machines saved'), findsOneWidget);
      expect(find.text('Add a machine'), findsOneWidget);
    });

    testWidgets('tapping an inactive machine switches to it', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoMachines(),
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

    testWidgets('the active machine is not a switch target', (tester) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
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
        connections: twoMachines(),
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
      expect(find.byType(InlineSpinner), findsOneWidget);

      // A second tap while the first is in flight must not queue another.
      await tester.tap(find.text('Laptop'), warnIfMissed: false);
      await tester.pump();
      expect(gateway.switchRequests, hasLength(1));

      await tester.pumpAndSettle();
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets('forgetting one machine asks first, then removes only it', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
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

    testWidgets('cancelling the forget dialog keeps the machine', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
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

    testWidgets('"Add a machine" opens the pairing flow', (tester) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      await tester.tap(find.text('Add a machine'));
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
    });
  });

  group('the switcher strip above the sessions', () {
    testWidgets('one machine is still named, and still offers another', (
      tester,
    ) async {
      // It used to hide itself below two machines, which is precisely what
      // made a second one undiscoverable: this strip is where "Add a machine"
      // lives.
      final gateway = FakeCompanionGateway.paired(
        connections: [
          CompanionConnection(hostId: studio, name: 'Studio', active: true),
        ],
      );
      await pumpPhone(tester, gateway: gateway, home: const HostSwitcherBar());

      expect(find.text('Studio'), findsOneWidget);
      expect(
        find.text('1 saved'),
        findsNothing,
        reason: 'a count of one is noise beside the name it counts',
      );

      await tester.tap(find.text('Studio'));
      await tester.pumpAndSettle();
      expect(find.text('Add a machine'), findsOneWidget);
    });

    testWidgets('two machines name the active one and how many are saved', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
      await pumpPhone(tester, gateway: gateway, home: const HostSwitcherBar());

      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('2 saved'), findsOneWidget);
    });

    testWidgets('the sheet switches machines in one tap', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        connections: twoMachines(),
        sessionsByHost: {
          laptop: [summary('s-laptop', title: 'Laptop work')],
        },
      );
      await pumpPhone(tester, gateway: gateway, home: const HostSwitcherBar());

      await tester.tap(find.text('Studio'));
      await tester.pumpAndSettle();
      // The sheet lists both; pick the other one.
      await tester.tap(find.text('Laptop').last);
      await tester.pumpAndSettle();

      expect(gateway.switchRequests, [laptop]);
    });

    testWidgets('the sheet also offers the way to a new machine', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
      await pumpPhone(tester, gateway: gateway, home: const HostSwitcherBar());

      await tester.tap(find.text('Studio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a machine'));
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
    });
  });

  group('in the shell', () {
    testWidgets('the strip rides above the Sessions tab, and the session '
        'list swaps with the machine', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [summary('s-studio', title: 'Studio work')],
        connections: twoMachines(),
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
        reason: "the old machine's sessions do not linger after a switch",
      );
    });

    testWidgets('the settings tab lists the machines', (tester) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
      await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('MACHINES'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.text('THIS CONNECTION'), findsOneWidget);
    });

    testWidgets('a single-machine phone is told which machine it is on', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [summary('s1')],
        connections: [
          CompanionConnection(hostId: studio, name: 'Studio', active: true),
        ],
      );
      await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

      expect(find.byType(HostSwitcherBar), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('1 saved'), findsNothing);
      expect(find.text('Session s1'), findsOneWidget);
    });
  });

  group('a switch that cannot reach its machine', () {
    testWidgets('lands on the chosen machine and says the host is '
        'unreachable — never silently back on the old one', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [summary('s-studio', title: 'Studio work')],
        connections: twoMachines(),
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
        reason: 'the phone is on the machine the user chose',
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
          _WedgedGateway(connections: twoMachines()),
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
        find.textContaining('No machines saved'),
        findsNothing,
        reason: 'an unanswered read is not the same fact as an empty phone',
      );
      expect(
        find.text('Add a machine'),
        findsOneWidget,
        reason: 'the section used to collapse, taking its one verb with it',
      );
      expect(find.text('MACHINES'), findsOneWidget);
    });

    testWidgets('and says it the moment an empty list arrives', (tester) async {
      final gateway = _SilentConnections();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );
      expect(find.textContaining('No machines saved'), findsNothing);

      gateway.deliver(const []);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No machines saved'),
        findsOneWidget,
        reason: 'loading and empty are two states, and this is the second',
      );
      expect(find.text('Add a machine'), findsOneWidget);
    });

    testWidgets('a list that arrives fills the same slot', (tester) async {
      final gateway = _SilentConnections();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
      );

      gateway.deliver(twoMachines());
      await tester.pumpAndSettle();

      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.textContaining('No machines saved'), findsNothing);
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
      expect(find.textContaining('No machines saved'), findsNothing);
      expect(find.text('Add a machine'), findsOneWidget);
    });
  });

  group('at 200% text', () {
    testWidgets('the connections section lists, badges and forgets without '
        'overflowing', (tester) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ConnectionsSection(),
        textScale: 2.0,
      );

      expect(find.text('MACHINES'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Add a machine'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the switcher strip keeps its name, count and caret on one '
        'row', (tester) async {
      final gateway = FakeCompanionGateway.paired(connections: twoMachines());
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
