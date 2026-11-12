import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';

import '../../support/fakes.dart';

class _OnScreen extends Notifier<String?> {
  @override
  String? build() => 'first';

  void show(String? id) => state = id;
}

final _onScreen = NotifierProvider<_OnScreen, String?>(_OnScreen.new);

/// **A session read in its own tab is seen on the dashboard** (owner,
/// 2026-11-12): only the dashboard's peek marked one before, so a session
/// read in the workbench stayed "new" there.
void main() {
  test(
    'a session coming on screen, and one leaving it, is marked seen',
    () async {
      final dir = await Directory.systemTemp.createTemp('ks-seen-follow');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold the file; the OS sweeps temp.
        }
      });
      final at = DateTime.utc(2026, 11, 12, 9);
      final c = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
          clockProvider.overrideWithValue(FixedClock(at)),
          onScreenSessionIdProvider.overrideWith((ref) => ref.watch(_onScreen)),
        ],
      );
      addTearDown(c.dispose);
      c.listen(overviewSeenFollowsScreenProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      // What was on screen when it started is seen.
      expect(c.read(overviewSeenProvider), {'first': at});

      c.read(_onScreen.notifier).show('second');
      await Future<void>.delayed(Duration.zero);
      expect(c.read(overviewSeenProvider).keys, {'first', 'second'});

      // The dashboard itself on screen marks nothing new.
      c.read(_onScreen.notifier).show(null);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(overviewSeenProvider).keys, {'first', 'second'});
    },
  );
}
