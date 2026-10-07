import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_batch.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_usage.dart';
import 'package:karmashala/src/features/sessions/application/session_usage_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'mission_fixture.dart';

/// Round 48's dashboard with every new piece showing: two pinned sessions,
/// two picked for a batch reply, usage on the cards with one "not recorded",
/// a limit warning, and — where the window has room — two peeks side by
/// side.
Future<ProviderContainer> pumpPowerBoard(
  WidgetTester tester, {
  required Directory prefsDir,
  required Size size,
  bool phone = false,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  GlobalKey? boundary,
  Widget Function(WorkspaceSessionEntry entry, DateTime? seenUntil)? peekChat,
}) async {
  final now = MissionFixture.now;
  final container = await pumpMission(
    tester,
    fixture: MissionFixture.full(peekChat: peekChat),
    prefsDir: prefsDir,
    size: size,
    phone: phone,
    brightness: brightness,
    textScale: textScale,
    boundary: boundary,
    overrides: [
      overviewTokenCountsProvider.overrideWith(
        (ref) async => {
          'ks-r32': 1834220,
          'ks-r21': 912400,
          'ks-release': 48210,
          'store-reviews': null,
        },
      ),
      sessionUsageProvider.overrideWith(
        (ref, id) => id == 'ks-r32'
            ? const SessionUsageChanged(
                sessionId: 'ks-r32',
                contextUsed: 81000,
                contextSize: 200000,
                costAmount: 3.18,
                costCurrency: 'USD',
              )
            : null,
      ),
      overviewLimitProvider.overrideWith(
        (ref, id) => id == 'ks-release'
            ? OverviewLimit(
                label: '5h',
                percent: 92,
                resetsAt: now.add(const Duration(minutes: 12)),
              )
            : null,
      ),
    ],
  );
  final prefs = container.read(overviewPrefsProvider.notifier);
  prefs
    ..togglePin('ks-r32')
    ..togglePin('ks-release');
  container.read(overviewSelectionProvider.notifier)
    ..toggle('ks-r21')
    ..toggle('store-reviews');
  if (!phone && size.width >= 1600) {
    container
        .read(overviewFocusProvider.notifier)
        .peekSideBySide('ks-r32', 'ks-release');
  }
  await settleMission(tester);
  return container;
}
