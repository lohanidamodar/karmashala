import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/notifications/application/focus_mode.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala_notifications/policy.dart';

import '../../support/fake_data_server.dart';

void main() {
  late ProviderContainer container;

  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('ks_focus_');
    // A prefs write may still hold its file, and Windows will not delete an
    // open one: try again until it lands.
    addTearDown(() async {
      for (var tries = 0; ; tries++) {
        try {
          return dir.deleteSync(recursive: true);
        } on FileSystemException {
          if (tries == 40) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final server = FakeDataServer();
    container = ProviderContainer(
      overrides: [
        await server.override(),
        sessionListPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(container.dispose);
    // Past the prefs file's first read, so it cannot land over a change.
    container.read(sessionListPrefsProvider);
    await pumpEventQueue();
  });

  NotifyLevel level() =>
      container.read(notificationSettingsControllerProvider).level;
  bool hiding() => container.read(hideWorkingSessionsProvider);
  FocusModeController focus() => container.read(focusModeProvider.notifier);

  void start(NotifyLevel level, {required bool hideWorking}) {
    container
        .read(notificationSettingsControllerProvider.notifier)
        .setLevel(level);
    container
        .read(sessionListPrefsProvider.notifier)
        .setHideWorking(hideWorking);
  }

  test('Focus is off to begin with', () {
    expect(container.read(focusModeProvider), isFalse);
  });

  test('on: Only when needed, and sessions hidden while working', () {
    start(NotifyLevel.everything, hideWorking: false);
    focus().set(true);

    expect(container.read(focusModeProvider), isTrue);
    expect(level(), NotifyLevel.whenNeeded);
    expect(hiding(), isTrue);
  });

  test('off: both back to what they were before Focus', () {
    start(NotifyLevel.everything, hideWorking: false);
    focus().set(true);
    focus().set(false);

    expect(container.read(focusModeProvider), isFalse);
    expect(level(), NotifyLevel.everything);
    expect(hiding(), isFalse);
  });

  test('restores Nothing, and a hide that was already on', () {
    start(NotifyLevel.nothing, hideWorking: true);
    focus().set(true);
    expect(level(), NotifyLevel.whenNeeded);
    expect(hiding(), isTrue);

    focus().set(false);
    expect(level(), NotifyLevel.nothing);
    expect(hiding(), isTrue);
  });

  test('on twice remembers the first: off still restores the original', () {
    start(NotifyLevel.everything, hideWorking: false);
    focus().set(true);
    focus().set(true);
    focus().set(false);

    expect(level(), NotifyLevel.everything);
    expect(hiding(), isFalse);
  });

  test('off while off changes nothing', () {
    start(NotifyLevel.nothing, hideWorking: true);
    focus().set(false);

    expect(level(), NotifyLevel.nothing);
    expect(hiding(), isTrue);
  });

  test('Focus is kept with the level, so a restart keeps it', () async {
    start(NotifyLevel.everything, hideWorking: false);
    focus().set(true);
    await pumpEventQueue();

    container.invalidate(notificationSettingsControllerProvider);
    expect(container.read(focusModeProvider), isTrue);
    expect(
      container.read(notificationSettingsControllerProvider).focus,
      const FocusMemory(level: NotifyLevel.everything, hideWorking: false),
    );
  });
}
