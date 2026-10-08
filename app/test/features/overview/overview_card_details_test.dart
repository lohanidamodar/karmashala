import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';

import 'mission_fixture.dart';

/// **Show on cards**: each part of a card's "where" line hides on its own,
/// is kept on this device, and a part every card in view shares is dropped.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-card-details');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  MissionFixture filed() => MissionFixture(
    activity: MissionFixture.realisticActivity(),
    contexts: const [
      OverviewLaneKey('c-apps', 'Apps'),
      OverviewLaneKey('c-web', 'Web'),
    ],
    contextOfProject: const {'p-ks': 'c-apps', 'p-beej': 'c-web'},
  );

  /// The header line of the card for `ks-r32`, a karmashala session on
  /// Windows filed under Apps.
  String placeOf(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('overview-card:ks-r32')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? '')
        .toList();
    return texts.firstWhere(
      (t) => t.contains('karmashala') || t.contains('Windows'),
      orElse: () => '',
    );
  }

  testWidgets('every part shows by default, and each toggle hides its own', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: filed(), prefsDir: dir);
    expect(placeOf(tester), 'Apps · karmashala · Windows');

    final prefs = c.read(overviewPrefsProvider.notifier);
    prefs.setDetailShown(OverviewCardDetail.project, false);
    await settleMission(tester);
    expect(placeOf(tester), 'Apps · Windows');

    prefs
      ..setDetailShown(OverviewCardDetail.project, true)
      ..setDetailShown(OverviewCardDetail.context, false);
    await settleMission(tester);
    expect(placeOf(tester), 'karmashala · Windows');

    prefs
      ..setDetailShown(OverviewCardDetail.context, true)
      ..setDetailShown(OverviewCardDetail.machine, false);
    await settleMission(tester);
    expect(placeOf(tester), 'Apps · karmashala');

    prefs
      ..setDetailShown(OverviewCardDetail.project, false)
      ..setDetailShown(OverviewCardDetail.context, false);
    await settleMission(tester);
    expect(placeOf(tester), isEmpty);
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });

  test('the prefs round-trip the hidden parts, and ignore unknown names', () {
    const prefs = OverviewPrefs(
      hiddenDetails: {OverviewCardDetail.context, OverviewCardDetail.machine},
    );
    expect(OverviewPrefs.fromJson(prefs.toJson()).hiddenDetails, {
      OverviewCardDetail.context,
      OverviewCardDetail.machine,
    });
    expect(
      OverviewPrefs.fromJson({
        'hiddenDetails': ['project', 'galaxy'],
      }).hiddenDetails,
      {OverviewCardDetail.project},
    );
    expect(const OverviewPrefs().toJson().containsKey('hiddenDetails'), false);
  });

  testWidgets('a part every card in view shares is dropped by itself', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: filed(), prefsDir: dir);
    // Only karmashala, all of it on one context: project and context say
    // nothing; its sessions run on more than one machine.
    _onlyProject(c, 'p-ks');
    await settleMission(tester);

    final details = c.read(overviewCardDetailsProvider);
    expect(details.shown, {OverviewCardDetail.machine});
    expect(details.same, {
      OverviewCardDetail.project,
      OverviewCardDetail.context,
    });
    expect(placeOf(tester), 'Windows');

    // Narrowed to Windows too, nothing on the line differs.
    c.read(overviewPrefsProvider.notifier).setMachines({'windows'});
    await settleMission(tester);
    expect(c.read(overviewCardDetailsProvider).shown, isEmpty);
    expect(placeOf(tester), isEmpty);
    await unmountMission(tester);
  });

  testWidgets('a part the person hid is not also counted as the same', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: filed(), prefsDir: dir);
    _onlyProject(c, 'p-ks');
    c
        .read(overviewPrefsProvider.notifier)
        .setDetailShown(OverviewCardDetail.project, false);
    await settleMission(tester);
    expect(c.read(overviewCardDetailsProvider).same, {
      OverviewCardDetail.context,
    });
    await unmountMission(tester);
  });
}

void _onlyProject(ProviderContainer c, String id) {
  final prefs = c.read(overviewPrefsProvider.notifier)..showAllProjects();
  for (final project in c.read(overviewFactsProvider).projects) {
    if (project.id == id) continue;
    prefs.toggleProject(
      project.id,
      all: [for (final p in c.read(overviewFactsProvider).projects) p.id],
    );
  }
}
