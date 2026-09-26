/// The desktop plugins `SystemIntegrationService` drives, behind seams: every
/// one is a channel-bound **singleton** a test cannot substitute or fail.
library;

import 'dart:async';
import 'dart:ui' show Size;

import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
// Prefixed on purpose: since 0.6 this is nativeapi's FFI surface, and `Image`,
// `Menu` and `MenuItem` are names this app already uses for other things.
import 'package:tray_manager/tray_manager.dart' as native;
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

/// A tray menu as plain data. `tray_manager` 0.6 replaced its declarative
/// `Menu` with live native objects that only exist once the FFI library is
/// loaded, so the description stops here and [PluginTrayAdapter] builds the
/// native menu from it.
class TrayMenu {
  const TrayMenu(this.items);

  final List<TrayMenuItem> items;
}

/// One entry of a [TrayMenu]. A non-null [checked] makes it a checkbox.
class TrayMenuItem {
  const TrayMenuItem({
    required this.key,
    required this.label,
    this.disabled = false,
  }) : checked = null,
       isSeparator = false;

  const TrayMenuItem.checkbox({
    required this.key,
    required this.label,
    required bool this.checked,
    this.disabled = false,
  }) : isSeparator = false;

  const TrayMenuItem.separator()
    : key = null,
      label = '',
      checked = null,
      disabled = true,
      isSeparator = true;

  /// What [TrayListener.onTrayMenuItemClicked] is given. Null for items that
  /// cannot be clicked.
  final String? key;
  final String label;
  final bool? checked;
  final bool disabled;
  final bool isSeparator;
}

/// What a tray reports. Named for the whole click nativeapi delivers rather
/// than the mouse-down half the 0.5.x plugin sent; Linux reports none of them.
mixin class TrayListener {
  void onTrayIconClicked() {}
  void onTrayIconRightClicked() {}
  void onTrayMenuItemClicked(String key) {}
}

/// Tray icon, tooltip and context menu.
abstract class TrayAdapter {
  Future<void> setIcon(String assetPath);
  Future<void> setToolTip(String tooltip);
  Future<void> setContextMenu(TrayMenu menu);
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
      tray = PluginTrayAdapter(),
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

/// The one tray icon, over `tray_manager` 0.7's nativeapi surface.
///
/// **Everything it makes has to be held.** A nativeapi wrapper frees its native
/// handle when it is collected, so a dropped `TrayIcon` takes the icon off the
/// tray and a dropped `MenuItem` takes its click listener with it.
class PluginTrayAdapter implements TrayAdapter {
  PluginTrayAdapter();

  final List<TrayListener> _listeners = [];

  native.TrayIcon? _trayIcon;
  native.Image? _icon;
  _NativeTrayMenu? _menu;
  native.ListenerId? _trayListenerId;

  /// Throws when the desktop has no tray to put an icon in — Wayland, or a
  /// GNOME without the AppIndicator extension. `SystemIntegrationService`
  /// reads that as "no tray" and stops hiding the window to one.
  native.TrayIcon get _ensureTrayIcon {
    var trayIcon = _trayIcon;
    if (trayIcon == null) {
      trayIcon = native.TrayIcon.create();
      if (trayIcon == null) {
        throw StateError('the system tray refused an icon');
      }
      trayIcon.setVisible(true);
      _trayIcon = trayIcon;
    }
    _wireTrayEvents(trayIcon);
    return trayIcon;
  }

  @override
  Future<void> setIcon(String assetPath) async {
    final image =
        native.ImageAsset.fromAsset(assetPath) ??
        native.Image.fromFile(assetPath);
    if (image == null) {
      throw ArgumentError.value(
        assetPath,
        'assetPath',
        'the tray icon could not be loaded',
      );
    }
    // The 0.5.x defaults, restated: only macOS reads the last three.
    _ensureTrayIcon
      ..isIconTemplate = false
      ..iconSize = const Size.square(18)
      ..iconPosition = native.TrayIconPosition.left
      ..icon = image
      ..setVisible(true);
    _icon?.dispose();
    _icon = image;
  }

  @override
  Future<void> setToolTip(String tooltip) async =>
      _ensureTrayIcon.setTooltip(tooltip);

  @override
  Future<void> setContextMenu(TrayMenu menu) async {
    final trayIcon = _ensureTrayIcon;
    final built = _NativeTrayMenu(menu, onClicked: _onMenuItemClicked);
    trayIcon.setContextMenu(built.menu);
    _disposeLater(_menu);
    _menu = built;
  }

  @override
  Future<void> popUpContextMenu() async => _ensureTrayIcon.openContextMenu();

  @override
  Future<void> destroy() async {
    _unwireTrayEvents();
    _disposeLater(_menu);
    _menu = null;
    _icon?.dispose();
    _icon = null;
    _trayIcon?.dispose();
    _trayIcon = null;
  }

  @override
  void addListener(TrayListener listener) {
    if (_listeners.contains(listener)) return;
    _listeners.add(listener);
    final trayIcon = _trayIcon;
    if (trayIcon != null) _wireTrayEvents(trayIcon);
  }

  @override
  void removeListener(TrayListener listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) _unwireTrayEvents();
  }

  void _wireTrayEvents(native.TrayIcon trayIcon) {
    if (_listeners.isEmpty || _trayListenerId != null) return;
    _trayListenerId = trayIcon.addListener((event) {
      for (final listener in List<TrayListener>.of(_listeners)) {
        switch (event) {
          case native.TrayIconClickedEvent():
            listener.onTrayIconClicked();
          case native.TrayIconRightClickedEvent():
            listener.onTrayIconRightClicked();
          case native.TrayIconDoubleClickedEvent():
            break;
        }
      }
    });
  }

  void _unwireTrayEvents() {
    final listenerId = _trayListenerId;
    if (listenerId != null) _trayIcon?.removeListener(listenerId);
    _trayListenerId = null;
  }

  void _onMenuItemClicked(String key) {
    for (final listener in List<TrayListener>.of(_listeners)) {
      listener.onTrayMenuItemClicked(key);
    }
  }

  /// A click handler rebuilds the menu (a checkbox item toggles a setting), and
  /// that runs inside the clicked item's own native callback — so the item it
  /// replaces has to outlive the call.
  void _disposeLater(_NativeTrayMenu? menu) {
    if (menu != null) Timer.run(menu.dispose);
  }
}

/// A [TrayMenu] built into a native menu, holding everything that has to stay
/// alive with it.
class _NativeTrayMenu {
  _NativeTrayMenu(TrayMenu source, {required this.onClicked}) {
    menu = _build(source);
  }

  final void Function(String key) onClicked;

  late final native.Menu menu;
  final List<native.MenuItem> _items = [];
  final List<(native.MenuItem, native.ListenerId)> _registrations = [];

  native.Menu _build(TrayMenu source) {
    final menu = native.Menu.create();
    if (menu == null) {
      throw StateError('the system refused a tray menu');
    }
    for (final item in source.items) {
      if (item.isSeparator) {
        menu.addSeparator();
        continue;
      }
      final checked = item.checked;
      final nativeItem = native.MenuItem.createWithLabelAndType(
        item.label,
        checked == null
            ? native.MenuItemType.normal
            : native.MenuItemType.checkbox,
      );
      if (nativeItem == null) {
        throw StateError('the system refused the tray menu item ${item.label}');
      }
      _items.add(nativeItem);
      nativeItem.isEnabled = !item.disabled;
      if (checked != null) nativeItem.state = _stateOf(checked);

      final key = item.key;
      if (key != null) {
        final listenerId = nativeItem.addListener((event) {
          if (event is! native.MenuItemClickedEvent) return;
          onClicked(key);
          // Some platforms tick a checkbox by themselves on click. The menu
          // shows what the app says it shows, so say it again; the rebuild the
          // click triggers is what carries the new value.
          if (checked != null) nativeItem.state = _stateOf(checked);
        });
        _registrations.add((nativeItem, listenerId));
      }
      menu.addItem(nativeItem);
    }
    return menu;
  }

  native.MenuItemState _stateOf(bool checked) => checked
      ? native.MenuItemState.checked
      : native.MenuItemState.unchecked;

  void dispose() {
    for (final (item, listenerId) in _registrations) {
      item.removeListener(listenerId);
    }
    _registrations.clear();
    for (final item in _items) {
      item.dispose();
    }
    _items.clear();
    menu.dispose();
  }
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
