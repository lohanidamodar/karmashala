import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/system/launcher_hotkey.dart';
import 'package:karmashala/src/features/system/native_status.dart';
import 'package:karmashala/src/features/system/system_integration_service.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';

import 'package:karmashala_terminal_runtime/instances.dart'
    show TerminalViewGate;
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
  /// What macOS's Quit would run. Captured rather than invoked through a
  /// platform channel, which needs a binding these tests do not have.
  Future<void> Function()? osQuit;

  late AppDatabase db;
  late ProviderContainer container;
  late FakeNatives natives;
  late SystemIntegrationService service;
  late List<String> quitCalls;
  late TerminalViewGate terminalViews;

  SettingsController settings() =>
      container.read(settingsControllerProvider.notifier);

  NativeSettingStatus? statusOf(NativeSetting setting) =>
      container.read(nativeIntegrationStatusProvider)[setting];

  Future<void> build() async {
    service = SystemIntegrationService(
      registerOsQuit: (quit) => osQuit = quit,
      endProcess: () {},
      container,
      adapters: natives.adapters,
      onQuitRequested: () async => quitCalls.add('shutdown'),
      terminalViews: terminalViews,
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
    terminalViews = TerminalViewGate();
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
        // `.ico` on Windows, `.png` everywhere else: macOS hands the path to
        // NSImage and Linux to the icon theme, and neither decodes ICO — an
        // `.ico` there is a status item that draws nothing at all.
        expect(
          natives.tray.icon,
          Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
        );
        expect(natives.tray.tooltip, 'Karmashala');
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

    test(
      'the OS Quit runs the ordered shutdown, close-to-tray or not',
      () async {
        // Cmd+Q is not a window close. `window_manager`'s prevent-close answers
        // `applicationShouldTerminate` with a window *close* event, so with
        // close-to-tray on the app used to hide instead of quitting and Cmd+Q
        // looked like it did nothing.
        await build();
        settings().setCloseToTray(true);
        await pumpEventQueue();

        expect(osQuit, isNotNull, reason: 'every desktop registers one');
        await osQuit!();
        await pumpEventQueue();

        expect(quitCalls, ['shutdown']);
        expect(natives.window.destroyed, isTrue);
      },
    );

    test('close to tray quits when there is no tray to close to', () async {
      // Stock GNOME has no StatusNotifier host unless an AppIndicator extension
      // is installed, so `setIcon` fails and nothing appears. Hiding there is
      // not close-to-tray, it is a window with no way back — and on Wayland the
      // global hotkey cannot rescue it either, because keybinder is X11-only.
      natives.tray.setIconFailure = Failure(StateError('no tray'), times: 99);

      await build();
      settings().setCloseToTray(true);
      await pumpEventQueue();

      service.onWindowClose();
      await pumpEventQueue();

      expect(statusOf(NativeSetting.trayIcon)!.ok, isFalse);
      expect(quitCalls, [
        'shutdown',
      ], reason: 'the X still runs the ordered teardown rather than hiding');
      expect(natives.window.destroyed, isTrue);
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
        registerOsQuit: (quit) => osQuit = quit,
        endProcess: () {},
        container,
        adapters: natives.adapters,
        onQuitRequested: () async => order.add('shutdown'),
      );
      await service.init();

      await service.quit();

      // The shutdown has to finish before the window goes: destroying it is
      // what the user sees, and a step that ran after would be invisible.
      expect(order, ['shutdown']);
      expect(natives.window.destroyed, isTrue);
      expect(natives.window.calls.indexOf('destroy'), greaterThan(-1));
    });

    test('quitting twice quits once', () async {
      // The macOS quit loop. `applicationShouldTerminate` cancels AppKit's own
      // termination so the ordered shutdown can run, then Dart destroys the
      // window — and destroying the last window makes AppKit ask again. The two
      // bounced off each other ~1400 times a second, running the shutdown over
      // a container the first pass had already disposed, and the app stayed up
      // with a dead container behind a live window: Cmd+Q looked like it did
      // nothing, and closing to the tray stopped working afterwards.
      final order = <String>[];
      var ended = 0;
      service = SystemIntegrationService(
        registerOsQuit: (quit) => osQuit = quit,
        endProcess: () => ended++,
        container,
        adapters: natives.adapters,
        onQuitRequested: () async => order.add('shutdown'),
      );
      await service.init();

      await service.quit();
      await service.quit();
      await service.quit();

      expect(order, ['shutdown'], reason: 'the shutdown runs once');
      expect(ended, 1, reason: 'and the process is ended once');
      expect(natives.window.calls.where((c) => c == 'destroy'), hasLength(1));
    });

    test('a shutdown hook that throws still lets the app close', () async {
      service = SystemIntegrationService(
        registerOsQuit: (quit) => osQuit = quit,
        endProcess: () {},
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

  group('terminal views', () {
    test(
      'are suspended while minimized, and a focus meanwhile keeps them so',
      () async {
        await build();
        expect(terminalViews.isSuspended, isFalse);

        service.onWindowEvent('minimize');
        expect(terminalViews.isSuspended, isTrue);
        service.onWindowEvent('focus');
        service.onWindowEvent('blur');
        expect(terminalViews.isSuspended, isTrue);

        service.onWindowEvent('restore');
        expect(terminalViews.isSuspended, isFalse);

        service.onWindowEvent('minimize');
        service.onWindowEvent('maximize');
        expect(terminalViews.isSuspended, isFalse);
      },
    );

    test('are suspended while hidden to the tray', () async {
      await build();
      service.onWindowEvent('hide');
      expect(terminalViews.isSuspended, isTrue);
      service.onWindowEvent('show');
      expect(terminalViews.isSuspended, isFalse);

      service.onWindowEvent('hide');
      await service.dispose();
      expect(terminalViews.isSuspended, isFalse, reason: 'never left shut');
    });
  });
}
