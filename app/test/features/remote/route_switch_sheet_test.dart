import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/server/machines.dart';
import 'package:karmashala/src/core/server/remote_server_access.dart';
import 'package:karmashala/src/features/remote/application/machines_providers.dart';
import 'package:karmashala/src/features/remote/presentation/route_switch_sheet.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart' show CapabilitySet, DeviceId;

const _hostId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _hosted = Uri.parse('wss://relay.example.test');
final _box = Uri.parse('ws://198.51.100.7:8787/k/secret-token');

CompanionPairing _machine({CompanionRoutePin? pin}) => CompanionPairing(
  hostId: DeviceId.parse(_hostId),
  deviceId: DeviceId.parse('99999999999999999999999999999999'),
  deviceKey: Uint8List(32),
  capabilities: CapabilitySet.all,
  relay: _hosted,
  candidates: [
    RelayCandidate(url: _hosted),
    RelayCandidate(url: _box),
  ],
  generation: 1,
  hostName: 'Studio',
  pin: pin,
);

/// The real access, with the pins it is told to obey recorded.
class _Access extends RemoteServerAccess {
  _Access(CompanionStore store)
    : super(
        hostId: _hostId,
        hostName: 'Studio',
        store: store,
        dialer: DesktopServerDialer(store: store),
      );

  final obeyed = <CompanionRoutePin>[];
  final redialled = <bool>[];

  @override
  Future<bool> obey(CompanionRoutePin pin) async {
    obeyed.add(pin);
    final redial = await super.obey(pin);
    redialled.add(redial);
    return redial;
  }
}

void main() {
  group('a pin redials only when the live route is not one it allows', () {
    late InMemoryCompanionStore store;
    late _Access access;

    setUp(() {
      store = InMemoryCompanionStore();
      access = _Access(store);
      addTearDown(access.close);
    });

    test('on a relay', () async {
      access.debugSetRoute(LiveLinkRoute(_box));
      expect(await access.obey(CompanionRoutePin.auto), isFalse);
      expect(await access.obey(CompanionRoutePin.relay(_box)), isFalse);
      expect(await access.obey(CompanionRoutePin.lan), isTrue);
      access.debugSetRoute(LiveLinkRoute(_box));
      expect(await access.obey(CompanionRoutePin.relay(_hosted)), isTrue);
    });

    test('on this network', () async {
      access.debugSetRoute(const LiveLinkRoute(null));
      expect(await access.obey(CompanionRoutePin.lan), isFalse);
      expect(await access.obey(CompanionRoutePin.relay(_box)), isTrue);
    });

    test('with no link, there is nothing to redial', () async {
      expect(await access.obey(CompanionRoutePin.lan), isFalse);
    });
  });

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    group(name, () {
      late InMemoryCompanionStore store;
      late _Access access;

      Future<void> open(
        WidgetTester tester, {
        CompanionRoutePin? pin,
        LiveLinkRoute? live,
      }) async {
        CompanionConnections.debugResetMutations();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        store = InMemoryCompanionStore();
        final machine = _machine(pin: pin);
        await machine.save(store);
        access = _Access(store);
        addTearDown(access.close);
        access.debugSetRoute(live);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              machinesProvider.overrideWithValue(Machines(store)),
              activeMachineProvider.overrideWithValue(machine),
              serverAccessProvider.overrideWithValue(access),
            ],
            child: const MaterialApp(
              home: Scaffold(body: Center(child: LinkRouteChip())),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link-route-chip')));
        await tester.pumpAndSettle();
      }

      Future<CompanionRoutePin> savedPin() async =>
          (await CompanionConnections.load(store)).byHost(_hostId)!.pin;

      void expectNoSecrets(WidgetTester tester) {
        for (final text in _texts(tester)) {
          expect(text, isNot(contains('secret-token')));
          expect(text, isNot(contains('/k/')));
        }
      }

      testWidgets('lists the route in use and every route to pin, by host '
          'and never by path', (tester) async {
        await open(tester, live: LiveLinkRoute(_box));
        expect(
          find.text('Now: through the relay at 198.51.100.7:8787'),
          findsOneWidget,
        );
        expect(find.text('Automatic'), findsOneWidget);
        expect(find.text('This network only'), findsOneWidget);
        expect(find.text('The relay at relay.example.test'), findsOneWidget);
        expect(find.text('The relay at 198.51.100.7:8787'), findsOneWidget);
        expectNoSecrets(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('one tap pins a route and redials off the one it '
          'disallows', (tester) async {
        await open(tester, live: LiveLinkRoute(_box));
        await tester.tap(find.text('This network only'));
        await tester.pumpAndSettle();
        expect(await savedPin(), CompanionRoutePin.lan);
        expect(access.obeyed, [CompanionRoutePin.lan]);
        expect(access.redialled, [isTrue]);
        expect(find.text('This network only'), findsNothing, reason: 'closed');
      });

      testWidgets('a pinned route that is not answering says so, and Use '
          'Auto clears the pin', (tester) async {
        await open(tester, pin: CompanionRoutePin.relay(_box));
        expect(find.textContaining("isn't answering"), findsOneWidget);
        expectNoSecrets(tester);
        await tester.tap(find.byKey(const ValueKey('route-switch-use-auto')));
        await tester.pumpAndSettle();
        expect(await savedPin(), CompanionRoutePin.auto);
        expect(access.obeyed, [CompanionRoutePin.auto]);
      });

      testWidgets('the chip names the route by host alone', (tester) async {
        CompanionConnections.debugResetMutations();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        store = InMemoryCompanionStore();
        final machine = _machine();
        await machine.save(store);
        access = _Access(store);
        addTearDown(access.close);
        access.debugSetRoute(LiveLinkRoute(_box));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              machinesProvider.overrideWithValue(Machines(store)),
              activeMachineProvider.overrideWithValue(machine),
              serverAccessProvider.overrideWithValue(access),
            ],
            child: const MaterialApp(home: Scaffold(body: LinkRouteChip())),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('198.51.100.7:8787'), findsOneWidget);
        access.debugSetRoute(const LiveLinkRoute(null));
        await tester.pumpAndSettle();
        expect(find.text('LAN'), findsOneWidget);
      });
    });
  }
}

/// Every string drawn on screen now.
Iterable<String> _texts(WidgetTester tester) sync* {
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    final text = widget.data ?? widget.textSpan?.toPlainText();
    if (text != null) yield text;
  }
}
