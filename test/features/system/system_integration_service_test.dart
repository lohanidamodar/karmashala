import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/system/launcher_hotkey.dart';
import 'package:chitragupta/src/features/system/native_status.dart';
import 'package:chitragupta/src/features/system/system_integration_service.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_native_adapters.dart';

/// `SystemIntegrationService` against its adapters.
///
/// The 2026-08-30 audit found this class had no tests at all, and that its
/// failure handling was `catch (_) {}` throughout — so a hotkey the OS refused
/// looked exactly like one it accepted, and `_appliedHotkeySignature` was set
/// *before* registration, which meant one refusal disabled the launcher chord
/// for the life of the process. Everything here is about the difference between
/// what the user asked for and what the OS did.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeNatives natives;
  late SystemIntegrationService service;
  late List<String> quitCalls;

  SettingsController settings() =>
      container.read(settingsControllerProvider.notifier);

  NativeSettingStatus? statusOf(NativeSetting setting) =>
      container.read(nativeIntegrationStatusProvider)[setting];

  Future<void> build() async {
    service = SystemIntegrationService(
      container,
      adapters: natives.adapters,
      onQuitRequested: () async => quitCalls.add('shutdown'),
    );
    await service.init();
  }

  setUp(() {
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    natives = FakeNatives();
    quitCalls = [];
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  group('initialization', () {
    test(
      'attaches to the window and the tray, and applies the settings',
      () async {
        await build();

        expect(natives.window.listeners, contains(service));
        expect(natives.tray.listeners, contains(service));
        expect(natives.tray.icon, 'assets/tray_icon.ico');
        expect(natives.tray.tooltip, 'Chitragupta');
        expect(natives.tray.menu, isNotNull);
        expect(natives.autoStart.setupCalled, isTrue);
        // Defaults: keep-awake off, close-to-tray off, hotkey on.
        expect(natives.wakelock.enabled, isFalse);
        // Prevent-close is not a setting: without it `WM_CLOSE` destroys the
        // window before `onWindowClose` is dispatched, so the ordered shutdown
        // would only ever run from the tray's Quit.
        expect(natives.window.preventClose, isTrue);
        expect(natives.hotkey.registered, hasLength(1));
        expect(
          launcherHotKeyLabel(natives.hotkey.registered.single),
          launcherHotKeyLabel(defaultLauncherHotKey()),
        );
      },
    );

    test('nothing is reported as failed when everything worked', () async {
      await build();

      expect(
        container
            .read(nativeIntegrationStatusProvider)
            .values
            .every((s) => s.ok),
        isTrue,
      );
    });

    test('a tray that will not take an icon does not stop the hotkey', () async {
      // Partial initialization: the audit's "similar empty catches around auto
      // start, tray icon/menu, window show/hide" — each one used to be able to
      // silently take the rest of init with it.
      natives.tray.setIconFailure = Failure(StateError('no tray'), times: 99);
      natives.autoStart.setupFailure = Failure(StateError('no path'));

      await build();

      expect(natives.hotkey.registered, hasLength(1));
      expect(natives.window.listeners, contains(service));
      expect(natives.tray.menu, isNotNull, reason: 'the menu still went up');
      expect(statusOf(NativeSetting.trayIcon)!.ok, isFalse);
      expect(statusOf(NativeSetting.launcherHotkey)!.ok, isTrue);
    });
  });

  group('a native call that fails', () {
    test('keep awake reports the reason instead of claiming success', () async {
      natives.wakelock.toggleFailure = Failure(
        StateError('no power manager'),
        times: 99,
      );
      await build();

      settings().setKeepAwake(true);
      await pumpEventQueue();

      final status = statusOf(NativeSetting.keepAwake)!;
      expect(status.ok, isFalse);
      expect(status.reason, contains('no power manager'));
      expect(
        status.messageFor(NativeSetting.keepAwake),
        'enabled — keep awake failed: Bad state: no power manager',
      );
      // The setting itself still persisted: the user's intent is not undone by
      // the OS refusing it.
      expect(container.read(settingsControllerProvider).keepAwake, isTrue);
    });

    test('prevent close reports and then recovers', () async {
      // Prevent-close is applied on the way up now, so the refusal has to land
      // there — a window that is not ready yet is exactly when it happens.
      natives.window.setPreventCloseFailure = Failure(StateError('not ready'));

      await build();
      expect(statusOf(NativeSetting.closeToTray)!.ok, isFalse);
      expect(natives.window.preventClose, isFalse);

      // The window came back: focus is the retry tick.
      service.onWindowFocus();
      await pumpEventQueue();

      expect(statusOf(NativeSetting.closeToTray)!.ok, isTrue);
      expect(natives.window.preventClose, isTrue);
    });

    test('launch at login surfaces a refused registry write', () async {
      natives.autoStart.enableFailure = Failure(
        StateError('registry write denied'),
        times: 99,
      );
      await build();

      settings().setAutoStart(true);
      await pumpEventQueue();

      expect(statusOf(NativeSetting.autoStart)!.ok, isFalse);
      expect(natives.autoStart.enabled, isFalse);
    });
  });

  group('the hotkey, which is what the bug was about', () {
    test('a collision does not mark the chord as applied', () async {
      // The real fixture: another application already owns Ctrl+Alt+Space.
      natives.hotkey.registerFailure = Failure(
        PlatformExceptionLike('hotkey already registered'),
        times: 99,
      );
      await build();

      expect(natives.hotkey.registered, isEmpty);
      final status = statusOf(NativeSetting.launcherHotkey)!;
      expect(status.ok, isFalse);
      expect(status.reason, contains('already registered'));
      expect(
        status.messageFor(NativeSetting.launcherHotkey),
        contains('hotkey registration failed'),
      );
    });

    test('the same configuration is retried, not written off', () async {
      // One refusal, then the other app lets go. Before Loop 61 the applied
      // signature was set before registering, so this second attempt never
      // happened for the rest of the process.
      natives.hotkey.registerFailure = Failure(PlatformExceptionLike('busy'));
      await build();
      expect(natives.hotkey.registered, isEmpty);

      service.onWindowFocus();
      await pumpEventQueue();

      expect(natives.hotkey.registered, hasLength(1));
      expect(statusOf(NativeSetting.launcherHotkey)!.ok, isTrue);
    });

    test('retrying is bounded, and changing the chord starts over', () async {
      natives.hotkey.registerFailure = Failure(
        PlatformExceptionLike('held by another app'),
        times: 99,
      );
      await build();

      for (var i = 0; i < 8; i++) {
        service.onWindowFocus();
        await pumpEventQueue();
      }
      final exhausted = statusOf(NativeSetting.launcherHotkey)!;
      expect(exhausted.exhausted, isTrue);
      expect(
        exhausted.attempts,
        4,
        reason: 'the budget stops the retries, it does not loop forever',
      );

      // The user picks a chord nobody else holds. A new desired value resets
      // the budget — this is the recovery path the settings line points at.
      natives.hotkey.registerFailure = null;
      settings().setLauncherHotkey(
        encodeLauncherHotKey(defaultLauncherHotKey()),
      );
      await pumpEventQueue();

      expect(natives.hotkey.registered, hasLength(1));
      expect(statusOf(NativeSetting.launcherHotkey)!.ok, isTrue);
    });

    test('turning it off unregisters and reports success', () async {
      await build();
      expect(natives.hotkey.registered, hasLength(1));

      settings().setLauncherHotkeyEnabled(false);
      await pumpEventQueue();

      expect(natives.hotkey.registered, isEmpty);
      expect(statusOf(NativeSetting.launcherHotkey)!.ok, isTrue);
    });

    test('an unchanged configuration is not re-registered', () async {
      await build();
      final before = natives.hotkey.unregisterAllCount;

      settings().setKeepAwake(true);
      await pumpEventQueue();

      expect(natives.hotkey.unregisterAllCount, before);
    });

    test('the registered handler summons the window', () async {
      await build();
      natives.window.visible = false;
      natives.window.focused = false;

      natives.hotkey.handler!(natives.hotkey.registered.single);
      await pumpEventQueue();

      expect(natives.window.visible, isTrue);
      expect(natives.window.calls, contains('show'));
    });
  });

  group('closing the window', () {
    test('prevent close is on whatever close to tray says', () async {
      // The whole point of A1: `window_manager` only routes `WM_CLOSE` to Dart
      // in time to act on it while prevent-close is set. Tying it to a setting
      // that ships off meant the X destroyed the window and the ordered
      // shutdown never ran.
      await build();
      expect(natives.window.preventClose, isTrue);

      settings().setCloseToTray(true);
      await pumpEventQueue();
      expect(natives.window.preventClose, isTrue);

      settings().setCloseToTray(false);
      await pumpEventQueue();
      expect(
        natives.window.preventClose,
        isTrue,
        reason: 'turning close-to-tray off must not turn the hook off',
      );
      // And it was applied once, not re-applied on every settings change.
      expect(
        natives.window.calls.where((c) => c == 'setPreventClose(true)'),
        hasLength(1),
      );
    });

    test('close to tray hides and does not quit', () async {
      await build();
      settings().setCloseToTray(true);
      await pumpEventQueue();

      service.onWindowClose();
      await pumpEventQueue();

      expect(natives.window.visible, isFalse);
      expect(natives.window.destroyed, isFalse);
      expect(quitCalls, isEmpty);
    });

    test('without close to tray it shuts down, then destroys', () async {
      await build();

      service.onWindowClose();
      await pumpEventQueue();

      expect(quitCalls, ['shutdown']);
      expect(natives.window.destroyed, isTrue);
    });

    test('the shutdown hook runs before the window is destroyed', () async {
      final order = <String>[];
      service = SystemIntegrationService(
        container,
        adapters: natives.adapters,
        onQuitRequested: () async => order.add('shutdown'),
      );
      await service.init();

      await service.quit();

      // `destroy()` ends the process; anything sequenced after it never runs.
      expect(order, ['shutdown']);
      expect(natives.window.destroyed, isTrue);
      expect(natives.window.calls.indexOf('destroy'), greaterThan(-1));
    });

    test('a shutdown hook that throws still lets the app close', () async {
      service = SystemIntegrationService(
        container,
        adapters: natives.adapters,
        onQuitRequested: () async => throw StateError('teardown blew up'),
      );
      await service.init();

      await service.quit();

      expect(natives.window.destroyed, isTrue);
    });
  });

  group('shutdown', () {
    test('detaches listeners, releases hotkeys and removes the icon', () async {
      await build();

      await service.dispose();

      expect(natives.window.listeners, isEmpty);
      expect(natives.tray.listeners, isEmpty);
      expect(natives.tray.destroyed, isTrue);
      // The unregister on the way out, on top of the one during init and the
      // one before registering.
      expect(natives.hotkey.calls.where((c) => c == 'unregisterAll').length, 3);
    });

    test('is idempotent', () async {
      await build();
      await service.dispose();
      final trayCalls = natives.tray.calls.length;

      await service.dispose();

      expect(natives.tray.calls, hasLength(trayCalls));
    });

    test(
      'a disposed service stops touching the OS on settings changes',
      () async {
        await build();
        await service.dispose();
        final toggles = natives.wakelock.toggles.length;

        await service.apply(
          container.read(settingsControllerProvider).copyWith(keepAwake: true),
        );

        expect(natives.wakelock.toggles, hasLength(toggles));
      },
    );
  });

  group('window size persistence', () {
    test('a real resize is stored', () async {
      await build();
      natives.window.size = const Size(1400, 900);

      service.onWindowResized();
      await pumpEventQueue();

      final settingsNow = container.read(settingsControllerProvider);
      expect(settingsNow.windowWidth, 1400);
      expect(settingsNow.windowHeight, 900);
    });

    test('a collapsed window is ignored', () async {
      await build();
      natives.window.size = const Size(100, 100);

      service.onWindowResized();
      await pumpEventQueue();

      expect(container.read(settingsControllerProvider).windowWidth, isNull);
    });
  });
}
