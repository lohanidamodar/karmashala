import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../settings/application/settings_controller.dart';
import '../settings/domain/settings.dart';

const _kMenuShow = 'show';
const _kMenuKeepAwake = 'keep_awake';
const _kMenuQuit = 'quit';

/// Wires the desktop OS integrations to the user [Settings]: a system tray icon
/// and menu, close-to-tray, keep-the-system-awake, and launch-at-login.
///
/// Lives outside the widget tree and is created only from `main()` on desktop —
/// every native call is guarded so a headless/unsupported host degrades quietly.
class SystemIntegrationService with TrayListener, WindowListener {
  SystemIntegrationService(this._container);

  final ProviderContainer _container;

  bool _closeToTray = false;
  bool _autoStartConfigured = false;

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  Settings get _settings => _container.read(settingsControllerProvider);
  SettingsController get _controller =>
      _container.read(settingsControllerProvider.notifier);

  /// Initializes the tray and window integration, applies the current settings,
  /// and starts listening for setting changes.
  Future<void> init() async {
    if (!isSupported) return;

    try {
      launchAtStartup.setup(
        appName: 'Chitragupta',
        appPath: Platform.resolvedExecutable,
      );
    } catch (_) {}

    windowManager.addListener(this);
    trayManager.addListener(this);

    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Chitragupta');
    } catch (_) {}

    await apply(_settings);

    _container.listen<Settings>(
      settingsControllerProvider,
      (_, next) => apply(next),
    );
  }

  /// Applies [settings] to the OS: keep-awake, close-to-tray, launch-at-login,
  /// and refreshes the tray menu.
  Future<void> apply(Settings settings) async {
    _closeToTray = settings.closeToTray;

    try {
      await WakelockPlus.toggle(enable: settings.keepAwake);
    } catch (_) {}

    try {
      await windowManager.setPreventClose(settings.closeToTray);
    } catch (_) {}

    await _applyAutoStart(settings.autoStart);
    await _refreshMenu(settings);
  }

  Future<void> _applyAutoStart(bool enabled) async {
    // Avoid redundant registry writes once configured the same way.
    if (_autoStartConfigured && enabled == await _isAutoStartEnabled()) return;
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      _autoStartConfigured = true;
    } catch (_) {}
  }

  Future<bool> _isAutoStartEnabled() async {
    try {
      return await launchAtStartup.isEnabled();
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshMenu(Settings settings) async {
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: _kMenuShow, label: 'Open Chitragupta'),
            MenuItem.separator(),
            MenuItem.checkbox(
              key: _kMenuKeepAwake,
              label: 'Keep system awake',
              checked: settings.keepAwake,
            ),
            MenuItem.separator(),
            MenuItem(key: _kMenuQuit, label: 'Quit'),
          ],
        ),
      );
    } catch (_) {}
  }

  Future<void> _showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _quit() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  // --- TrayListener ---

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _kMenuShow:
        _showWindow();
      case _kMenuKeepAwake:
        _controller.setKeepAwake(!_settings.keepAwake);
      case _kMenuQuit:
        _quit();
    }
  }

  // --- WindowListener ---

  @override
  void onWindowClose() {
    if (_closeToTray) {
      windowManager.hide();
    } else {
      _quit();
    }
  }
}
