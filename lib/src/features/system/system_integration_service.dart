import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/shell/quick_open/quick_open.dart';
import '../notifications/application/attention_inbox.dart';
import '../notifications/application/notification_providers.dart';
import '../notifications/domain/inbox_item.dart';
import '../notifications/domain/notification_settings.dart';
import '../settings/application/settings_controller.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import '../settings/domain/settings.dart';
import 'launcher_hotkey.dart';

const _kMenuShow = 'show';
const _kMenuHide = 'hide';
const _kMenuKeepAwake = 'keep_awake';
const _kMenuNotifications = 'notifications';
const _kMenuOnlyWhenUnfocused = 'notifications_unfocused';
const _kMenuQuit = 'quit';

/// Prefix for the per-session "needs you" items; the suffix is the index into
/// [SystemIntegrationService._pending].
const _kMenuAttentionPrefix = 'attention:';

const _kIdleTrayIcon = 'assets/tray_icon.ico';
const _kAttentionTrayIcon = 'assets/tray_icon_attention.ico';

/// How many waiting sessions the tray menu names before it summarises the rest.
/// A tray menu is a glance, not a list view.
const _kMaxAttentionItems = 5;

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

  /// The last hotkey config applied, so [apply] only re-registers when it
  /// actually changes (re-registering on every settings change is wasteful and
  /// can briefly drop the global binding).
  String? _appliedHotkeySignature;

  /// What the attention inbox has that the user has not seen, as the tray
  /// shows it.
  ///
  /// Deliberately the *inbox* and not the raw attention set. Loop 42 badged the
  /// set of sessions currently in a waiting status, which meant a finished turn
  /// never reached the tray at all and a session whose status report went stale
  /// silently un-badged itself. One list, one count, three surfaces.
  List<InboxItem> _pending = const [];

  /// How many were showing last time the icon and tooltip were set, so the
  /// native calls only happen when the count actually moved. `-1` forces the
  /// first apply.
  int _appliedAttentionCount = -1;

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
      await trayManager.setIcon(_kIdleTrayIcon);
      await trayManager.setToolTip('Chitragupta');
    } catch (_) {}

    await apply(_settings);

    _container.listen<Settings>(
      settingsControllerProvider,
      (_, next) => apply(next),
    );

    // Agent status → tray. The icon and menu are ambient state, so they follow
    // what needs the user regardless of focus; the interrupting half (toasts)
    // is the dispatcher's job, behind the policy.
    _container.listen<AttentionInbox>(
      attentionInboxProvider,
      (_, next) => unawaited(_applyAttention(next)),
    );
    _container.listen<NotificationSettings>(
      notificationSettingsControllerProvider,
      (_, _) => unawaited(_refreshMenu(_settings)),
    );
    // A clicked toast asks for the window, from outside the widget tree.
    _container.listen<int>(
      windowRaiseRequestProvider,
      (_, _) => unawaited(_raiseWindow()),
    );

    _container.read(agentStatusWatcherProvider).start();
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

  /// Global-hotkey handler: a summon/dismiss toggle for the whole app.
  ///
  /// Chitragupta used to answer this with a second window — a borderless
  /// always-on-top mini launcher with its own list of projects and sessions,
  /// its own size and position, and its own chat. Quick open does that job
  /// inside the window the user already has, over more than projects and
  /// sessions, so the hotkey now brings *the app* forward with the palette up
  /// and puts it away again when it is already in front.
  Future<void> _summonLauncher() async {
    try {
      if (await windowManager.isVisible() && await windowManager.isFocused()) {
        await windowManager.hide();
        return;
      }
    } catch (_) {
      // An unavailable window manager must not swallow the hotkey; fall
      // through and try to show.
    }
    await _showWindow();
    _container.read(quickOpenRequestProvider.notifier).bump();
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

  /// Reflects the current attention set in the tray: a badged icon, a tooltip
  /// that says how many, and the menu section that lists them.
  Future<void> _applyAttention(AttentionInbox inbox) async {
    _pending = inbox.pending;
    final count = inbox.unseen;
    if (count != _appliedAttentionCount) {
      final wasBadged = _appliedAttentionCount > 0;
      final isBadged = count > 0;
      _appliedAttentionCount = count;
      try {
        if (wasBadged != isBadged) {
          await trayManager.setIcon(
            isBadged ? _kAttentionTrayIcon : _kIdleTrayIcon,
          );
        }
        await trayManager.setToolTip(_toolTip(count));
      } catch (_) {}
    }
    await _refreshMenu(_settings);
  }

  String _toolTip(int count) => switch (count) {
    0 => 'Chitragupta',
    1 => 'Chitragupta — 1 thing needs you',
    _ => 'Chitragupta — $count things need you',
  };

  Future<void> _refreshMenu(Settings settings) async {
    final notifications = _container.read(
      notificationSettingsControllerProvider,
    );
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            ..._attentionMenuItems(),
            MenuItem.separator(),
            MenuItem(key: _kMenuShow, label: 'Open Chitragupta'),
            MenuItem(key: _kMenuHide, label: 'Hide window'),
            MenuItem.separator(),
            MenuItem.checkbox(
              key: _kMenuKeepAwake,
              label: 'Keep system awake',
              checked: settings.keepAwake,
            ),
            MenuItem.checkbox(
              key: _kMenuNotifications,
              label: 'Notify me about agents',
              checked: notifications.enabled,
            ),
            MenuItem.checkbox(
              key: _kMenuOnlyWhenUnfocused,
              label: 'Only when the window is not focused',
              checked: notifications.onlyWhenUnfocused,
              disabled: !notifications.enabled,
            ),
            MenuItem.separator(),
            MenuItem(key: _kMenuQuit, label: 'Quit'),
          ],
        ),
      );
    } catch (_) {}
  }

  /// The "needs you" section: one clickable item per waiting session, or a
  /// disabled line when nothing does — an empty tray menu reads as broken.
  List<MenuItem> _attentionMenuItems() {
    if (_pending.isEmpty) {
      return [
        MenuItem(
          key: 'attention_none',
          label: 'Nothing needs you',
          disabled: true,
        ),
      ];
    }
    final shown = _pending.take(_kMaxAttentionItems).toList();
    return [
      for (var i = 0; i < shown.length; i++)
        MenuItem(key: '$_kMenuAttentionPrefix$i', label: shown[i].menuLabel),
      if (_pending.length > shown.length)
        MenuItem(
          key: 'attention_more',
          label: '+${_pending.length - shown.length} more',
          disabled: true,
        ),
    ];
  }

  /// Brings the app forward on the session behind tray item [index].
  void _openAttention(int index) {
    if (index < 0 || index >= _pending.length) return;
    // Through the inbox, so opening from the tray marks the item seen and the
    // badge, the rail and the status bar all drop by one together.
    _container.read(attentionInboxProvider.notifier).open(_pending[index]);
    unawaited(_raiseWindow());
  }

  Future<void> _raiseWindow() => _showWindow();

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
    final key = menuItem.key;
    if (key != null && key.startsWith(_kMenuAttentionPrefix)) {
      final index = int.tryParse(key.substring(_kMenuAttentionPrefix.length));
      if (index != null) _openAttention(index);
      return;
    }
    switch (key) {
      case _kMenuShow:
        _showWindow();
      case _kMenuHide:
        windowManager.hide();
      case _kMenuKeepAwake:
        _controller.setKeepAwake(!_settings.keepAwake);
      case _kMenuNotifications:
        final notifications = _container.read(
          notificationSettingsControllerProvider.notifier,
        );
        notifications.setEnabled(
          !_container.read(notificationSettingsControllerProvider).enabled,
        );
      case _kMenuOnlyWhenUnfocused:
        final notifications = _container.read(
          notificationSettingsControllerProvider.notifier,
        );
        notifications.setOnlyWhenUnfocused(
          !_container
              .read(notificationSettingsControllerProvider)
              .onlyWhenUnfocused,
        );
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
  void onWindowFocus() =>
      _container.read(windowFocusedProvider.notifier).set(true);

  @override
  void onWindowBlur() {
    // Notifications only fire while the window is unfocused, so this is the
    // signal that opens that gate.
    _container.read(windowFocusedProvider.notifier).set(false);
  }

  @override
  void onWindowResized() => _saveWindowSize();

  Future<void> _saveWindowSize() async {
    try {
      final size = await windowManager.getSize();
      if (size.width < 200 || size.height < 200) return;
      _controller.setWindowSize(size.width, size.height);
    } catch (_) {}
  }
}
