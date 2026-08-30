import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/shell/app_mode.dart';
import '../mcp/launcher_chat_controller.dart';
import '../settings/application/settings_controller.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import '../settings/domain/settings.dart';
import 'launcher_hotkey.dart';

const _kMenuShow = 'show';
const _kMenuMini = 'mini';
const _kMenuHide = 'hide';
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

  /// True briefly while the mini launcher is being summoned, so the focus
  /// transition doesn't trigger an immediate blur-hide.
  bool _summoning = false;

  /// The last hotkey config applied, so [apply] only re-registers when it
  /// actually changes (re-registering on every settings change is wasteful and
  /// can briefly drop the global binding).
  String? _appliedHotkeySignature;

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

    // Clear any stale system hotkeys left registered by a previous run/crash
    // before we register ours (recommended by hotkey_manager).
    try {
      await hotKeyManager.unregisterAll();
    } catch (_) {}

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
    await _applyLauncherHotkey(settings);
    await _refreshMenu(settings);
  }

  /// Registers (or clears) the global launcher hotkey to match [settings],
  /// re-registering only when the hotkey or its enabled state changed.
  Future<void> _applyLauncherHotkey(Settings settings) async {
    final signature = settings.launcherHotkeyEnabled
        ? (settings.launcherHotkeyJson ?? 'default')
        : 'disabled';
    if (signature == _appliedHotkeySignature) return;
    _appliedHotkeySignature = signature;

    try {
      await hotKeyManager.unregisterAll();
      if (!settings.launcherHotkeyEnabled) return;
      await hotKeyManager.register(
        decodeLauncherHotKey(settings.launcherHotkeyJson),
        keyDownHandler: (_) => _summonLauncher(),
      );
    } catch (_) {
      // Registration can fail if the combo is already held by another app;
      // leave the launcher reachable via the tray/app-bar buttons.
    }
  }

  /// Global-hotkey handler. Toggles the mini launcher: if it is already
  /// showing, hide it; otherwise bring it up in chat mode with the input
  /// focused. A brief guard stops the show transition from self-dismissing via
  /// [onWindowBlur].
  Future<void> _summonLauncher() async {
    final inMini = _container.read(appModeProvider) == AppMode.mini;
    if (inMini && await windowManager.isVisible()) {
      await windowManager.hide();
      return;
    }
    _summoning = true;
    _container.read(launcherChatVisibleProvider.notifier).set(true);
    _container.read(appModeProvider.notifier).enterMini();
    await _showWindow();
    _container.read(launcherFocusRequestProvider.notifier).bump();
    Future.delayed(const Duration(milliseconds: 500), () {
      _summoning = false;
    });
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
            MenuItem(key: _kMenuMini, label: 'Mini launcher'),
            MenuItem(key: _kMenuHide, label: 'Hide window'),
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

  /// Toggles window visibility: hide when it's already up front, otherwise bring
  /// it back. Used by the tray icon click.
  Future<void> _toggleWindow() async {
    try {
      final visible = await windowManager.isVisible();
      final focused = visible && await windowManager.isFocused();
      if (visible && focused) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    } catch (_) {}
  }

  Future<void> _quit() async {
    _saveTerminalWorkspace();
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  /// Snapshots the terminal workspace on the way out.
  ///
  /// `windowManager.destroy()` ends the process without disposing the provider
  /// container, so the controller's own teardown hook never runs — without this
  /// the last thing the user did before quitting is the one thing that does not
  /// come back.
  ///
  /// Guarded by [ProviderContainer.exists] so quitting never *creates* the
  /// terminal controller: building it would restore a workspace only to write
  /// it straight back.
  void _saveTerminalWorkspace() {
    try {
      if (!_container.exists(terminalSessionsControllerProvider)) return;
      // persistWorkspace re-encodes every pane, so it covers the autosave too.
      _container
          .read(terminalSessionsControllerProvider.notifier)
          .persistWorkspace();
    } catch (_) {
      // Never block quitting on persistence.
    }
  }

  // --- TrayListener ---

  @override
  void onTrayIconMouseDown() => _toggleWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _kMenuShow:
        _container.read(appModeProvider.notifier).enterFull();
        _showWindow();
      case _kMenuMini:
        _container.read(appModeProvider.notifier).enterMini();
      case _kMenuHide:
        windowManager.hide();
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

  @override
  void onWindowBlur() {
    // The mini launcher is ephemeral: dismiss it when it loses focus (click
    // away / Alt-Tab). Only in mini mode, and not during the summon transition.
    if (_summoning) return;
    if (_container.read(appModeProvider) != AppMode.mini) return;
    unawaited(_hideIfVisible());
  }

  Future<void> _hideIfVisible() async {
    try {
      if (await windowManager.isVisible()) await windowManager.hide();
    } catch (_) {}
  }

  @override
  void onWindowResized() => _saveWindowSize();

  Future<void> _saveWindowSize() async {
    try {
      final size = await windowManager.getSize();
      if (size.width < 200 || size.height < 200) return;
      // Persist the mini size separately so resizing the mini launcher doesn't
      // clobber the full-window size (and vice versa).
      if (_container.read(appModeProvider) == AppMode.mini) {
        _controller.setMiniSize(size.width, size.height);
      } else {
        _controller.setWindowSize(size.width, size.height);
      }
    } catch (_) {}
  }
}
