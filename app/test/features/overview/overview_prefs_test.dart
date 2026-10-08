import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';

/// **What the Overview shows is kept per device**: the projects side by side,
/// the other filters, the rows, the density and the view.
void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-prefs');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  ProviderContainer open() {
    final c = ProviderContainer(
      overrides: [
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('every project shows until some are picked', () {
    final prefs = open().read(overviewPrefsProvider);
    expect(prefs.filter.projects, isNull);
    expect(prefs.groupBy, OverviewGroupBy.project);
    expect(prefs.view, OverviewView.board);
    expect(prefs.density, OverviewDensity.cards);
  });

  test('the multi-project filter is kept across a reload', () async {
    final first = open();
    final prefs = first.read(overviewPrefsProvider.notifier);
    prefs.toggleProject('p1', all: const ['p1', 'p2', 'p3']);
    prefs.toggleProject('p3', all: const ['p1', 'p2', 'p3']);
    // Two of three unpicked leaves p2 alone.
    expect(first.read(overviewPrefsProvider).filter.projects, {'p2'});
    prefs.toggleProject('p1', all: const ['p1', 'p2', 'p3']);
    prefs
      ..setGroupBy(OverviewGroupBy.machine)
      ..setDensity(OverviewDensity.lines)
      ..setView(OverviewView.timeline)
      ..setColumns({BoardColumn.needsYou});
    final file = File(
      '${dir.path}${Platform.pathSeparator}overview_device.json',
    );
    await until(
      () =>
          file.existsSync() &&
          file.readAsStringSync().contains('timeline') &&
          file.readAsStringSync().contains('needsYou'),
    );

    final second = open();
    second.read(overviewPrefsProvider);
    await until(
      () => second.read(overviewPrefsProvider).filter.projects != null,
    );
    final kept = second.read(overviewPrefsProvider);
    expect(kept.filter.projects, {'p1', 'p2'});
    expect(kept.groupBy, OverviewGroupBy.machine);
    expect(kept.density, OverviewDensity.lines);
    expect(kept.view, OverviewView.timeline);
    expect(kept.filter.columns, {BoardColumn.needsYou});
  });

  test('grouping by context is kept across a reload', () async {
    final first = open();
    first
        .read(overviewPrefsProvider.notifier)
        .setGroupBy(OverviewGroupBy.context);
    final file = File(
      '${dir.path}${Platform.pathSeparator}overview_device.json',
    );
    await until(
      () => file.existsSync() && file.readAsStringSync().contains('context'),
    );

    final second = open();
    second.read(overviewPrefsProvider);
    await until(
      () =>
          second.read(overviewPrefsProvider).groupBy != OverviewGroupBy.project,
    );
    expect(second.read(overviewPrefsProvider).groupBy, OverviewGroupBy.context);
  });

  test('picking every project again is "all", so new projects show', () {
    final c = open();
    final prefs = c.read(overviewPrefsProvider.notifier);
    prefs.toggleProject('p1', all: const ['p1', 'p2']);
    prefs.toggleProject('p1', all: const ['p1', 'p2']);
    expect(c.read(overviewPrefsProvider).filter.projects, isNull);
    prefs.showAllProjects();
    expect(c.read(overviewPrefsProvider).filter.projects, isNull);
  });

  test('the Failed counter is kept apart from Needs you, across a reload', () {
    final kept = OverviewPrefs.fromJson(
      const OverviewPrefs(
        filter: OverviewFilter(
          columns: {BoardColumn.needsYou},
          states: {AgentState.failed},
        ),
      ).toJson(),
    );
    expect(OverviewCounter.failed.selectedIn(kept.filter), isTrue);
    expect(OverviewCounter.needsYou.selectedIn(kept.filter), isFalse);
    expect(kept.filter.shows(AgentState.failed), isTrue);
    expect(kept.filter.shows(AgentState.needsYou), isFalse);
  });

  test('resuming and starting in the background is on until turned off, '
      'and kept', () {
    expect(const OverviewPrefs().launchInBackground, isTrue);
    final kept = OverviewPrefs.fromJson(
      const OverviewPrefs(launchInBackground: false).toJson(),
    );
    expect(kept.launchInBackground, isFalse);
    // The dialogs' own keys from before the setting decide nothing now.
    expect(
      OverviewPrefs.fromJson({
        'newSessionKeepsHere': false,
        'resumeKeepsHere': false,
      }).launchInBackground,
      isTrue,
    );
  });

  test('the choice is kept in this device\'s file', () async {
    final folder = Directory.systemTemp.createTempSync('ks-r56-prefs');
    addTearDown(() => folder.deleteSync(recursive: true));
    ProviderContainer make() {
      final c = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => folder),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    make().read(overviewPrefsProvider.notifier).setLaunchInBackground(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final again = make()..read(overviewPrefsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(again.read(overviewPrefsProvider).launchInBackground, isFalse);
  });
}
