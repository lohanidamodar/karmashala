import 'dart:ui' show Size;

import 'package:karmashala/src/features/system/native_adapters.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Stand-ins for the five desktop plugins, recording what they were asked to do
/// and failing on demand.
///
/// The point of the whole adapter layer: `windowManager`, `trayManager`,
/// `hotKeyManager`, `launchAtStartup` and `WakelockPlus` are singletons over
/// platform channels. Nothing can substitute them, so before Loop 61 nothing
/// could test what happened when one of them said no.

/// A call that should throw the next `count` times it is made.
class Failure {
  Failure(this.error, {this.times = 1});

  final Object error;
  int times;

  /// Consumes one occurrence, returning whether it should throw now.
  bool shouldThrow() {
    if (times <= 0) return false;
    times--;
    return true;
  }
}

class FakeWindowAdapter implements WindowAdapter {
  final List<String> calls = [];
  final List<WindowListener> listeners = [];

  bool visible = true;
  bool focused = true;
  Size size = const Size(1200, 800);
  bool preventClose = false;
  bool destroyed = false;

  Failure? setPreventCloseFailure;
  Failure? showFailure;

  @override
  Future<void> setPreventClose(bool value) async {
    calls.add('setPreventClose($value)');
    if (setPreventCloseFailure?.shouldThrow() ?? false) {
      throw StateError('the window is not ready');
    }
    preventClose = value;
  }

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<bool> isFocused() async => focused;

  @override
  Future<void> show() async {
    calls.add('show');
    if (showFailure?.shouldThrow() ?? false) throw StateError('no window');
    visible = true;
  }

  @override
  Future<void> focus() async {
    calls.add('focus');
    focused = true;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    visible = false;
    focused = false;
  }

  @override
  Future<Size> getSize() async => size;

  @override
  Future<void> setPreventCloseAndDestroy() async {
    calls.add('destroy');
    preventClose = false;
    destroyed = true;
  }

  @override
  void addListener(WindowListener listener) {
    calls.add('addListener');
    listeners.add(listener);
  }

  @override
  void removeListener(WindowListener listener) {
    calls.add('removeListener');
    listeners.remove(listener);
  }
}

class FakeTrayAdapter implements TrayAdapter {
  final List<String> calls = [];
  final List<TrayListener> listeners = [];

  String? icon;
  String? tooltip;
  Menu? menu;
  bool destroyed = false;

  Failure? setIconFailure;
  Failure? setContextMenuFailure;

  /// Runs when the tray is torn down, so a shutdown-order test can see where
  /// this step landed relative to the others.
  void Function()? onDestroy;

  /// Makes teardown take this long, for the shutdown-deadline tests.
  Duration? destroyDelay;

  @override
  Future<void> setIcon(String assetPath) async {
    calls.add('setIcon($assetPath)');
    if (setIconFailure?.shouldThrow() ?? false) {
      throw StateError('no tray available');
    }
    icon = assetPath;
  }

  @override
  Future<void> setToolTip(String value) async {
    calls.add('setToolTip');
    tooltip = value;
  }

  @override
  Future<void> setContextMenu(Menu value) async {
    calls.add('setContextMenu');
    if (setContextMenuFailure?.shouldThrow() ?? false) {
      throw StateError('menu rejected');
    }
    menu = value;
  }

  @override
  Future<void> popUpContextMenu() async => calls.add('popUpContextMenu');

  @override
  Future<void> destroy() async {
    calls.add('destroy');
    if (destroyDelay case final delay?) await Future<void>.delayed(delay);
    destroyed = true;
    onDestroy?.call();
  }

  @override
  void addListener(TrayListener listener) {
    calls.add('addListener');
    listeners.add(listener);
  }

  @override
  void removeListener(TrayListener listener) {
    calls.add('removeListener');
    listeners.remove(listener);
  }
}

class FakeHotkeyAdapter implements HotkeyAdapter {
  final List<String> calls = [];

  /// Every chord successfully registered, newest last.
  final List<HotKey> registered = [];

  /// The handler the service passed with the last successful registration.
  void Function(HotKey)? handler;

  int unregisterAllCount = 0;

  /// The collision fixture: the OS refusing a chord another app already holds.
  Failure? registerFailure;

  @override
  Future<void> unregisterAll() async {
    calls.add('unregisterAll');
    unregisterAllCount++;
    registered.clear();
  }

  @override
  Future<void> register(HotKey hotKey, void Function(HotKey) onKeyDown) async {
    calls.add('register');
    if (registerFailure?.shouldThrow() ?? false) {
      throw PlatformExceptionLike('hotkey already registered by another app');
    }
    registered.add(hotKey);
    handler = onKeyDown;
  }
}

/// A stand-in for the plugin's own platform exception, without depending on
/// Flutter's services layer in a pure Dart test.
class PlatformExceptionLike implements Exception {
  PlatformExceptionLike(this.message);

  final String message;

  @override
  String toString() => message;
}

class FakeAutoStartAdapter implements AutoStartAdapter {
  final List<String> calls = [];

  bool enabled = false;
  bool setupCalled = false;

  Failure? setupFailure;
  Failure? enableFailure;

  @override
  void setup({required String appName, required String appPath}) {
    calls.add('setup');
    if (setupFailure?.shouldThrow() ?? false) {
      throw StateError('cannot resolve the executable');
    }
    setupCalled = true;
  }

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> enable() async {
    calls.add('enable');
    if (enableFailure?.shouldThrow() ?? false) {
      throw StateError('registry write denied');
    }
    enabled = true;
  }

  @override
  Future<void> disable() async {
    calls.add('disable');
    enabled = false;
  }
}

class FakeWakelockAdapter implements WakelockAdapter {
  final List<bool> toggles = [];

  bool? enabled;
  Failure? toggleFailure;

  @override
  Future<void> toggle({required bool enable}) async {
    toggles.add(enable);
    if (toggleFailure?.shouldThrow() ?? false) {
      throw StateError('no power manager');
    }
    enabled = enable;
  }
}

/// All five, with handles on each.
class FakeNatives {
  FakeNatives();

  final window = FakeWindowAdapter();
  final tray = FakeTrayAdapter();
  final hotkey = FakeHotkeyAdapter();
  final autoStart = FakeAutoStartAdapter();
  final wakelock = FakeWakelockAdapter();

  NativeAdapters get adapters => NativeAdapters(
    window: window,
    tray: tray,
    hotkey: hotkey,
    autoStart: autoStart,
    wakelock: wakelock,
  );
}
