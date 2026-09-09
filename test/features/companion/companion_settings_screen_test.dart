/// The settings screen says which path carries the link — "Direct (LAN)" at
/// home, "Relay" from anywhere — and, per CLAUDE.md §19, how long the link has
/// been in the state it is claiming.
library;

import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:karmashala/src/features/companion/presentation/companion_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'companion_test_support.dart';

/// The instant the screen is rendered at, so every age below is the one the
/// stamp was written for rather than whatever the wall clock says.
final _now = DateTime.utc(2026, 9, 9, 12);

class _FixedClock implements Clock {
  const _FixedClock(this._instant);
  final DateTime _instant;

  @override
  DateTime nowUtc() => _instant;
}

List<Override> _clockAt(DateTime now) => [
  clockProvider.overrideWithValue(_FixedClock(now)),
];

void main() {
  testWidgets('a connected link names its path, and follows it moving', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      linkPath: CompanionLinkPath.lan,
      linkSince: _now.subtract(const Duration(minutes: 4)),
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
      overrides: _clockAt(_now),
    );

    expect(find.text('Connected · Direct (LAN) · 4m'), findsOneWidget);

    gateway.setLinkPath(CompanionLinkPath.relay);
    await tester.pump();
    await tester.pump();

    // The path moved; the link never dropped, so the age keeps running.
    expect(find.text('Connected · Relay · 4m'), findsOneWidget);
    expect(find.textContaining('Direct (LAN)'), findsNothing);
  });

  testWidgets('a downed link shows the outage, not a stale path', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      link: CompanionLinkState.disconnected,
      linkSince: _now.subtract(const Duration(minutes: 12)),
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
      overrides: _clockAt(_now),
    );

    expect(find.text('Host unreachable · since 12m ago'), findsOneWidget);
    expect(find.textContaining('Connected'), findsNothing);
  });

  testWidgets('a link still dialling says how long it has been trying', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(
        link: CompanionLinkState.connecting,
        linkSince: _now.subtract(const Duration(hours: 2)),
      ),
      home: const CompanionSettingsScreen(),
      overrides: _clockAt(_now),
    );

    expect(find.text('Connecting… · 2h'), findsOneWidget);
  });

  testWidgets('a reading with no stamp admits it rather than saying "now"', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(linkPath: CompanionLinkPath.lan),
      home: const CompanionSettingsScreen(),
      overrides: _clockAt(_now),
    );

    expect(find.text('Connected · Direct (LAN) · age unknown'), findsOneWidget);
    expect(find.textContaining('· now'), findsNothing);
  });

  test('the stamp moves on a change and not on a repeated report', () async {
    final held = _now.subtract(const Duration(minutes: 4));
    var now = _now;
    final gateway = FakeCompanionGateway.paired(
      linkPath: CompanionLinkPath.lan,
      linkSince: held,
      now: () => now,
    );
    final frames = <DateTime?>[];
    final sub = gateway.linkSinceStates.listen(frames.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();

    expect(frames, [held]);

    // The transports report the state they are IN, so the same reading
    // arrives again and again; none of it is a change.
    now = _now.add(const Duration(minutes: 1));
    gateway.setLink(CompanionLinkState.connected);
    gateway.setLinkPath(CompanionLinkPath.lan);
    gateway.setLink(CompanionLinkState.connected);
    await pumpEventQueue();

    expect(frames, [held]);

    gateway.setLink(CompanionLinkState.disconnected);
    await pumpEventQueue();

    expect(frames, [held, now]);
  });

  testWidgets('the whole settings screen survives 200% text', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      link: CompanionLinkState.disconnected,
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
      textScale: 2.0,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Every section still names itself; a heading that vanished at large text
    // would take the structure of the screen with it.
    for (final heading in const [
      'PAIRED DESKTOP',
      'THIS CONNECTION',
      'PAIRING RELAY',
      'DIAGNOSTICS',
    ]) {
      await tester.scrollUntilVisible(
        find.text(heading),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(heading), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('every section heading is a header for a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionSettingsScreen(),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('THIS CONNECTION')),
      matchesSemantics(label: 'THIS CONNECTION', isHeader: true),
    );
    handle.dispose();
  });
}
