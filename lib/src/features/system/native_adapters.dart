/// The desktop plugins `SystemIntegrationService` drives, behind seams: every
/// one is a channel-bound **singleton** a test cannot substitute or fail.
library;

import 'dart:ui' show Size;

import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

/// Window: visibility, focus, close behaviour, size, teardown.
abstract class WindowAdapter {
  Future<void> setPreventClose(bool value);
  Future<bool> isVisible();
  Future<bool> isFocused();
  Future<void> show();
  Future<void> focus();
  Future<void> hide();
  Future<Size> getSize();
  Future<void> setPreventCloseAndDestroy();
  void addListener(WindowListener listener);
  void removeListener(WindowListener listener);
}

/// Tray icon, tooltip and context menu.
abstract class TrayAdapter {
  Future<void> setIcon(String assetPath);
  Future<void> setToolTip(String tooltip);
  Future<void> setContextMenu(Menu menu);
  Future<void> popUpContextMenu();
  Future<void> destroy();
  void addListener(TrayListener listener);
  void removeListener(TrayListener listener);
}

/// The global launcher chord.
abstract class HotkeyAdapter {
  Future<void> unregisterAll();
  Future<void> register(HotKey hotKey, void Function(HotKey) onKeyDown);
}

/// Launch at login.
abstract class AutoStartAdapter {
  void setup({required String appName, required String appPath});
  Future<bool> isEnabled();
  Future<void> enable();
  Future<void> disable();
}

/// Keep the machine awake.
abstract class WakelockAdapter {
  Future<void> toggle({required bool enable});
}

/// The five seams, passed as one so a caller substitutes what it cares about
/// and leaves the rest real.
class NativeAdapters {
  const NativeAdapters({
    required this.window,
    required this.tray,
    required this.hotkey,
    required this.autoStart,
    required this.wakelock,
  });

  /// The plugins as they actually are.
  NativeAdapters.platform()
    : window = const PluginWindowAdapter(),
      tray = const PluginTrayAdapter(),
      hotkey = const PluginHotkeyAdapter(),
      autoStart = const PluginAutoStartAdapter(),
      wakelock = const PluginWakelockAdapter();

  final WindowAdapter window;
  final TrayAdapter tray;
  final HotkeyAdapter hotkey;
  final AutoStartAdapter autoStart;
  final WakelockAdapter wakelock;
}

class PluginWindowAdapter implements WindowAdapter {
  const PluginWindowAdapter();

  @override
  Future<void> setPreventClose(bool value) =>
      windowManager.setPreventClose(value);

  @override
  Future<bool> isVisible() => windowManager.isVisible();

  @override
  Future<bool> isFocused() => windowManager.isFocused();

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<Size> getSize() => windowManager.getSize();

  /// Clearing prevent-close first is what makes `destroy` actually end the
  /// process rather than route back through `onWindowClose`.
  @override
  Future<void> setPreventCloseAndDestroy() async {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void addListener(WindowListener listener) =>
      windowManager.addListener(listener);

  @override
  void removeListener(WindowListener listener) =>
      windowManager.removeListener(listener);
}

class PluginTrayAdapter implements TrayAdapter {
  const PluginTrayAdapter();

  @override
  Future<void> setIcon(String assetPath) => trayManager.setIcon(assetPath);

  @override
  Future<void> setToolTip(String tooltip) => trayManager.setToolTip(tooltip);

  @override
  Future<void> setContextMenu(Menu menu) => trayManager.setContextMenu(menu);

  @override
  Future<void> popUpContextMenu() => trayManager.popUpContextMenu();

  @override
  Future<void> destroy() => trayManager.destroy();

  @override
  void addListener(TrayListener listener) => trayManager.addListener(listener);

  @override
  void removeListener(TrayListener listener) =>
      trayManager.removeListener(listener);
}

class PluginHotkeyAdapter implements HotkeyAdapter {
  const PluginHotkeyAdapter();

  @override
  Future<void> unregisterAll() => hotKeyManager.unregisterAll();

  @override
  Future<void> register(HotKey hotKey, void Function(HotKey) onKeyDown) =>
      hotKeyManager.register(hotKey, keyDownHandler: onKeyDown);
}

class PluginAutoStartAdapter implements AutoStartAdapter {
  const PluginAutoStartAdapter();

  @override
  void setup({required String appName, required String appPath}) =>
      launchAtStartup.setup(appName: appName, appPath: appPath);

  @override
  Future<bool> isEnabled() => launchAtStartup.isEnabled();

  @override
  Future<void> enable() => launchAtStartup.enable();

  @override
  Future<void> disable() => launchAtStartup.disable();
}

class PluginWakelockAdapter implements WakelockAdapter {
  const PluginWakelockAdapter();

  @override
  Future<void> toggle({required bool enable}) =>
      WakelockPlus.toggle(enable: enable);
}
