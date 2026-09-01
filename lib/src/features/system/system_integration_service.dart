import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/shell/quick_open/quick_open.dart';
import '../../core/logging/app_logger.dart';
import '../notifications/application/attention_inbox.dart';
import '../notifications/application/notification_providers.dart';
import '../notifications/domain/inbox_item.dart';
import '../notifications/domain/notification_settings.dart';
import '../settings/application/settings_controller.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import '../settings/domain/settings.dart';
import 'launcher_hotkey.dart';
import 'native_adapters.dart';
import 'native_status.dart';

const _kMenuShow = 'show';
const _kMenuHide = 'hide';
const _kMenuKeepAwake = 'keep_awake';
const _kMenuNotifications = 'notifications';
const _kMenuOnlyWhenUnfocused = 'notifications_unfocused';
const _kMenuQuit = 'quit';

/// Where `applicationShouldTerminate` asks Dart to quit. See `AppDelegate`.
const MethodChannel _lifecycleChannel = MethodChannel('karmashala/lifecycle');

/// Installs [quit] as what the OS's Quit runs.
typedef OsQuitRegistrar = void Function(Future<void> Function() quit);

/// The real one: macOS's `applicationShouldTerminate` cancels its own
/// termination and calls `quitRequested` here instead, so Cmd+Q gets the same
/// ordered shutdown as the tray's Quit.
void registerOsQuitOverChannel(Future<void> Function() quit) {
  _lifecycleChannel.setMethodCallHandler((call) async {
    if (call.method == 'quitRequested') unawaited(quit());
  });
}

/// Prefix for the per-session "needs you" items; the suffix is the index into
/// [SystemIntegrationService._pending].
const _kMenuAttentionPrefix = 'attention:';

/// The tray icons, in the format the host platform's tray can actually decode.
///
/// Windows wants a multi-size `.ico`; macOS hands the path to `NSImage` and
/// Linux to the icon theme, and neither reads ICO — an `.ico` there is not an
/// error, just a status item that draws nothing. Both are produced from the
/// same source by `dart run tool/icon/write_ico.dart`.
final String _kIdleTrayIcon = Platform.isWindows
    ? 'assets/tray_icon.ico'
    : 'assets/tray_icon.png';
final String _kAttentionTrayIcon = Platform.isWindows
    ? 'assets/tray_icon_attention.ico'
    : 'assets/tray_icon_attention.png';

/// How many waiting sessions the tray menu names before it summarises the rest.
/// A tray menu is a glance, not a list view.
const _kMaxAttentionItems = 5;

/// How many times one desired native value is attempted before the service
/// stops retrying it on its own.
///
/// Bounded because the common failure — another application already owns the
/// chord — does not resolve on its own, and a service that kept asking would
/// spend a platform call on every window focus for the rest of the session.
/// Changing the setting resets the budget, which is the case that *does*
/// resolve: the user picks a chord nobody else holds.
const _kMaxNativeAttempts = 4;

Future<void> _noShutdown() async {}

/// Wires the desktop OS integrations to the user [Settings]: a system tray icon
/// and menu, close-to-tray, keep-the-system-awake, and launch-at-login.
///
/// Lives outside the widget tree and is created only from the app lifecycle
/// owner on desktop. Every platform call goes through [NativeAdapters], so a
/// test can make any of them fail; before Loop 61 they were direct singleton
/// calls wrapped in `catch (_) {}`, which meant a failed hotkey registration
/// was indistinguishable from a successful one — to the user *and* to the
/// suite.
///
/// ## Desired versus applied
///
/// Settings say what the user wants; the OS says what it did. The two are kept
/// apart deliberately. An applied marker is written **only after the platform
/// call returns**, so a transient failure leaves the desired value outstanding
/// and it is tried again — on the next settings change, and on the next window
/// focus, up to [_kMaxNativeAttempts]. The bug this replaces set the applied
/// marker *before* registering, so one failure disabled the launcher hotkey for
/// the lifetime of the process.
/// Holds the running integration so the menu bar's Quit can take the same
/// graceful path the tray's does. Null until the desktop integration starts,
/// and for the whole life of companion mode.
class SystemIntegrationHolder extends Notifier<SystemIntegrationService?> {
  @override
  SystemIntegrationService? build() => null;

  void adopt(SystemIntegrationService service) => state = service;
}

final systemIntegrationProvider =
    NotifierProvider<SystemIntegrationHolder, SystemIntegrationService?>(
      SystemIntegrationHolder.new,
    );

class SystemIntegrationService with TrayListener, WindowListener {
  SystemIntegrationService(
    this._container, {
    NativeAdapters? adapters,
    AppLogger? logger,
    Future<void> Function()? onQuitRequested,
    OsQuitRegistrar? registerOsQuit,
  }) : _native = adapters ?? NativeAdapters.platform(),
       _logger = logger ?? AppLogger.named('system'),
       _onQuitRequested = onQuitRequested ?? _noShutdown,
       _registerOsQuit = registerOsQuit ?? registerOsQuitOverChannel;

  /// How the OS's own Quit reaches this service.
  ///
  /// A seam rather than a channel because a `MethodChannel` cannot even be
  /// *handed a handler* without a Flutter binding, and these are unit tests
  /// with no binding — the same reason every other native here is injected.
  final OsQuitRegistrar _registerOsQuit;

  final ProviderContainer _container;
  final NativeAdapters _native;
  final AppLogger _logger;

  /// Runs before the window is destroyed, so the lifecycle owner can shut the
  /// rest of the app down in order. A no-op outside the app (tests, tools).
  final Future<void> Function() _onQuitRequested;

  /// Whether closing the window hides to the tray instead of quitting.
  ///
  /// Read by [onWindowClose] and nothing else. Prevent-close is deliberately
  /// *not* derived from it — see [apply].
  bool _closeToTray = false;

  /// Whether the tray icon actually went up.
  ///
  /// Hiding to a tray that is not there is a window the user cannot get back:
  /// on stock GNOME there is no StatusNotifier host unless an AppIndicator
  /// extension is installed, so `setIcon` fails and nothing appears — and with
  /// the global hotkey needing X11 (keybinder has no Wayland support), a
  /// Wayland session has no second way in either. [onWindowClose] falls back to
  /// an ordered quit when this is false.
  bool _trayIconApplied = false;
  bool _disposed = false;

  /// What the user asked for, kept separately from what the OS confirmed.
  bool? _desiredKeepAwake;
  bool? _appliedKeepAwake;
  bool? _desiredPreventClose;
  bool? _appliedPreventClose;
  bool? _desiredAutoStart;
  bool? _appliedAutoStart;

  /// The hotkey config the user wants, and the one actually registered. These
  /// are only equal once [HotkeyAdapter.register] has returned.
  String? _desiredHotkeySignature;
  String? _appliedHotkeySignature;

  /// Attempts spent on the current desired value, per setting.
  final Map<NativeSetting, int> _attempts = {};

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
  ///
  /// Each step is independent: a tray that will not accept an icon must not
  /// stop the hotkey from registering, and neither must stop the listeners
  /// being attached. What failed is recorded rather than swallowed.
  Future<void> init() async {
    if (!isSupported) return;

    try {
      _native.autoStart.setup(
        appName: 'Karmashala',
        appPath: Platform.resolvedExecutable,
      );
    } on Object catch (error, stack) {
      _logger.warning(
        'system: launch-at-startup setup failed reason=$error',
        error,
        stack,
      );
    }

    _native.window.addListener(this);
    _native.tray.addListener(this);

    // Clear any stale system hotkeys left registered by a previous run/crash
    // before we register ours (recommended by hotkey_manager).
    try {
      await _native.hotkey.unregisterAll();
    } on Object catch (error, stack) {
      _logger.warning(
        'system: clearing stale hotkeys failed reason=$error',
        error,
        stack,
      );
    }

    // macOS routes Cmd+Q here rather than terminating, so the same ordered
    // shutdown runs for it as for the tray's Quit. Without this the app menu's
    // Quit was swallowed: `window_manager`'s prevent-close answers
    // `applicationShouldTerminate` with a *window close*, and with
    // close-to-tray on that hid the window instead of quitting.
    if (Platform.isMacOS) {
      _registerOsQuit(() => _quit());
    }

    _trayIconApplied = await _run(NativeSetting.trayIcon, () async {
      await _native.tray.setIcon(_kIdleTrayIcon);
      await _native.tray.setToolTip('Karmashala');
    });

    await apply(_settings);

    _container.listen<Settings>(
      settingsControllerProvider,
      (_, next) => unawaited(apply(next)),
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
  ///
  /// Prevent-close is the one value here that is **not** a setting. It is
  /// applied unconditionally, because it is what makes `WM_CLOSE` reach Dart at
  /// all: `window_manager` posts `close` over a method channel and then, unless
  /// prevent-close is on, falls straight through to `DefWindowProc` — the
  /// window is destroyed before [onWindowClose] is dispatched. Deriving it from
  /// `closeToTray` (off by default) therefore meant the ordered shutdown ran on
  /// the tray's Quit and on nothing else: closing with the X skipped the
  /// handshake deletion, the hook rewrite, the hotkey release and the PTY reap.
  /// [_closeToTray] keeps its job — [onWindowClose] decides hide versus quit —
  /// and clearing prevent-close is already part of destroying the window
  /// (`PluginWindowAdapter.setPreventCloseAndDestroy`).
  Future<void> apply(Settings settings) async {
    if (_disposed) return;
    _closeToTray = settings.closeToTray;
    _want(NativeSetting.keepAwake, settings.keepAwake, _desiredKeepAwake);
    _desiredKeepAwake = settings.keepAwake;
    _want(NativeSetting.closeToTray, true, _desiredPreventClose);
    _desiredPreventClose = true;
    _want(NativeSetting.autoStart, settings.autoStart, _desiredAutoStart);
    _desiredAutoStart = settings.autoStart;

    final signature = settings.launcherHotkeyEnabled
        ? (settings.launcherHotkeyJson ?? 'default')
        : 'disabled';
    _want(NativeSetting.launcherHotkey, signature, _desiredHotkeySignature);
    _desiredHotkeySignature = signature;

    await _reconcile(settings);
    await _refreshMenu(settings);
  }

  /// A new desired value resets that setting's retry budget: the reason the old
  /// one kept failing may be exactly what the user just changed.
  void _want(NativeSetting setting, Object? next, Object? previous) {
    if (next != previous) _attempts.remove(setting);
  }

  /// Brings the OS in line with the desired values, skipping whatever already
  /// matches and whatever has spent its retry budget.
  Future<void> _reconcile(Settings settings) async {
    if (_desiredKeepAwake != _appliedKeepAwake &&
        _hasBudget(NativeSetting.keepAwake)) {
      final want = _desiredKeepAwake!;
      if (await _run(
        NativeSetting.keepAwake,
        () => _native.wakelock.toggle(enable: want),
      )) {
        _appliedKeepAwake = want;
      }
    }

    // Constant now, but still reconciled: the platform call can be refused
    // while the window is coming up, and this is what retries it on focus.
    if (_desiredPreventClose != _appliedPreventClose &&
        _hasBudget(NativeSetting.closeToTray)) {
      final want = _desiredPreventClose!;
      if (await _run(
        NativeSetting.closeToTray,
        () => _native.window.setPreventClose(want),
      )) {
        _appliedPreventClose = want;
      }
    }

    if (_desiredAutoStart != _appliedAutoStart &&
        _hasBudget(NativeSetting.autoStart)) {
      await _applyAutoStart(_desiredAutoStart!);
    }

    if (_desiredHotkeySignature != _appliedHotkeySignature &&
        _hasBudget(NativeSetting.launcherHotkey)) {
      await _applyLauncherHotkey(settings);
    }
  }

  /// Retries whatever the OS has not confirmed yet.
  ///
  /// Window focus is the cheap, well-timed signal for this: the user has just
  /// come back to the app, and the conditions that make these calls fail —
  /// another application holding the chord, a machine still waking up, a tray
  /// that was not ready — are exactly the ones that change while it is in the
  /// background.
  Future<void> retryOutstanding() async {
    if (_disposed || !isSupported) return;
    await _reconcile(_settings);
  }

  bool _hasBudget(NativeSetting setting) =>
      (_attempts[setting] ?? 0) < _kMaxNativeAttempts;

  /// Runs one platform call, records what happened, and never throws.
  Future<bool> _run(
    NativeSetting setting,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      _attempts.remove(setting);
      _record(setting, const NativeSettingStatus.applied());
      return true;
    } on Object catch (error, stack) {
      final attempts = (_attempts[setting] ?? 0) + 1;
      _attempts[setting] = attempts;
      final exhausted = attempts >= _kMaxNativeAttempts;
      _logger.warning(
        'system: ${setting.name} failed attempt=$attempts '
        'exhausted=$exhausted reason=$error',
        error,
        stack,
      );
      _record(
        setting,
        NativeSettingStatus.failed(
          '$error',
          attempts: attempts,
          exhausted: exhausted,
        ),
      );
      return false;
    }
  }

  /// Publishes one setting's native state.
  ///
  /// A platform call that was still in flight when the app started shutting
  /// down would otherwise land on a disposed container — a crash on the way
  /// out, in the code whose whole job is to make failures visible.
  void _record(NativeSetting setting, NativeSettingStatus status) {
    if (_disposed) return;
    try {
      _container
          .read(nativeIntegrationStatusProvider.notifier)
          .record(setting, status);
    } on Object catch (error) {
      _logger.warning('system: could not publish native status: $error');
    }
  }

  /// Registers (or clears) the global launcher hotkey to match [settings].
  ///
  /// [_appliedHotkeySignature] is written **after** the registration returns,
  /// so a chord another application is holding is retried rather than recorded
  /// as done.
  Future<void> _applyLauncherHotkey(Settings settings) async {
    final signature = _desiredHotkeySignature;
    final ok = await _run(NativeSetting.launcherHotkey, () async {
      await _native.hotkey.unregisterAll();
      if (!settings.launcherHotkeyEnabled) return;
      await _native.hotkey.register(
        decodeLauncherHotKey(settings.launcherHotkeyJson),
        (_) => _summonLauncher(),
      );
    });
    if (ok) _appliedHotkeySignature = signature;
  }

  /// Global-hotkey handler: a summon/dismiss toggle for the whole app.
  ///
  /// Karmashala used to answer this with a second window — a borderless
  /// always-on-top mini launcher with its own list of projects and sessions,
  /// its own size and position, and its own chat. Quick open does that job
  /// inside the window the user already has, over more than projects and
  /// sessions, so the hotkey now brings *the app* forward with the palette up
  /// and puts it away again when it is already in front.
  Future<void> _summonLauncher() async {
    try {
      if (await _native.window.isVisible() &&
          await _native.window.isFocused()) {
        await _native.window.hide();
        return;
      }
    } on Object catch (error) {
      // An unavailable window manager must not swallow the hotkey; fall
      // through and try to show.
      _logger.warning('system: window state unreadable reason=$error');
    }
    await _showWindow();
    _container.read(quickOpenRequestProvider.notifier).bump();
  }

  Future<void> _applyAutoStart(bool enabled) async {
    // Avoid a redundant registry write when the OS already agrees.
    if (_appliedAutoStart != null && enabled == await _isAutoStartEnabled()) {
      _appliedAutoStart = enabled;
      _record(NativeSetting.autoStart, const NativeSettingStatus.applied());
      return;
    }
    final ok = await _run(
      NativeSetting.autoStart,
      () => enabled ? _native.autoStart.enable() : _native.autoStart.disable(),
    );
    if (ok) _appliedAutoStart = enabled;
  }

  Future<bool> _isAutoStartEnabled() async {
    try {
      return await _native.autoStart.isEnabled();
    } on Object catch (error) {
      _logger.warning('system: reading launch-at-login failed reason=$error');
      return false;
    }
  }

  /// Reflects the current attention set in the tray: a badged icon, a tooltip
  /// that says how many, and the menu section that lists them.
  Future<void> _applyAttention(AttentionInbox inbox) async {
    if (_disposed) return;
    _pending = inbox.pending;
    final count = inbox.unseen;
    if (count != _appliedAttentionCount) {
      final wasBadged = _appliedAttentionCount > 0;
      final isBadged = count > 0;
      _appliedAttentionCount = count;
      await _run(NativeSetting.trayIcon, () async {
        if (wasBadged != isBadged) {
          await _native.tray.setIcon(
            isBadged ? _kAttentionTrayIcon : _kIdleTrayIcon,
          );
        }
        await _native.tray.setToolTip(_toolTip(count));
      });
    }
    await _refreshMenu(_settings);
  }

  String _toolTip(int count) => switch (count) {
    0 => 'Karmashala',
    1 => 'Karmashala — 1 thing needs you',
    _ => 'Karmashala — $count things need you',
  };

  Future<void> _refreshMenu(Settings settings) async {
    if (_disposed) return;
    final notifications = _container.read(
      notificationSettingsControllerProvider,
    );
    await _run(
      NativeSetting.trayMenu,
      () => _native.tray.setContextMenu(
        Menu(
          items: [
            ..._attentionMenuItems(),
            MenuItem.separator(),
            MenuItem(key: _kMenuShow, label: 'Open Karmashala'),
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
      ),
    );
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
      await _native.window.show();
      await _native.window.focus();
    } on Object catch (error) {
      _logger.warning('system: showing the window failed reason=$error');
    }
  }

  /// Toggles window visibility: hide when it's already up front, otherwise bring
  /// it back. Used by the tray icon click.
  Future<void> _toggleWindow() async {
    try {
      final visible = await _native.window.isVisible();
      final focused = visible && await _native.window.isFocused();
      if (visible && focused) {
        await _native.window.hide();
      } else {
        await _native.window.show();
        await _native.window.focus();
      }
    } on Object catch (error) {
      _logger.warning('system: toggling the window failed reason=$error');
    }
  }

  /// Quits the application.
  ///
  /// The workspace snapshot goes first and synchronously, then the lifecycle
  /// owner gets its ordered shutdown, and only then is the window destroyed —
  /// `destroy()` ends the process, so anything after it does not happen.
  /// The one graceful exit, shared by the tray's Quit and the menu bar's.
  Future<void> quit() => _quit();

  Future<void> _quit() async {
    _saveTerminalWorkspace();
    try {
      await _onQuitRequested();
    } on Object catch (error, stack) {
      // A shutdown step that fails must not strand the user in an app that
      // will not close.
      _logger.warning('system: shutdown before quit failed.', error, stack);
    }
    try {
      await _native.window.setPreventCloseAndDestroy();
    } on Object catch (error) {
      _logger.warning('system: window destroy failed reason=$error');
      exit(0);
    }
  }

  /// Snapshots the terminal workspace on the way out.
  ///
  /// First, and synchronously, before anything else in the quit sequence gets a
  /// chance to fail or time out. Loop 38 and Loop 53 both landed here: without
  /// this call the last thing the user did before quitting is the one thing
  /// that does not come back. The lifecycle owner does now dispose the
  /// container, which would run the controller's own teardown — but that
  /// happens inside a bounded budget, several steps later, and the workspace is
  /// not something to leave to a step that is allowed to be abandoned.
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
    } on Object catch (error) {
      // Never block quitting on persistence.
      _logger.warning('system: persisting the workspace failed reason=$error');
    }
  }

  /// Detaches from the OS: listeners off, hotkeys released, tray icon removed.
  ///
  /// Ordered so the app stops *receiving* events before it stops being able to
  /// answer them. Idempotent, and every step is independent — one platform call
  /// that hangs or throws must not leave the rest attached.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!isSupported) return;

    try {
      _native.window.removeListener(this);
    } on Object catch (error) {
      _logger.warning('system: detaching the window listener failed: $error');
    }
    try {
      _native.tray.removeListener(this);
    } on Object catch (error) {
      _logger.warning('system: detaching the tray listener failed: $error');
    }

    try {
      await _native.hotkey.unregisterAll();
    } on Object catch (error) {
      _logger.warning('system: releasing hotkeys failed reason=$error');
    }
    try {
      await _native.tray.destroy();
    } on Object catch (error) {
      _logger.warning('system: removing the tray icon failed reason=$error');
    }
  }

  // --- TrayListener ---

  @override
  void onTrayIconMouseDown() => unawaited(_toggleWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(_native.tray.popUpContextMenu());

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
        unawaited(_showWindow());
      case _kMenuHide:
        unawaited(_native.window.hide());
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
        unawaited(_quit());
    }
  }

  // --- WindowListener ---

  /// The window's X.
  ///
  /// Reached only because prevent-close is on (see [apply]); without it the
  /// window is already gone by the time this runs. The quit branch is the same
  /// ordered teardown the tray's Quit uses.
  ///
  /// Close-to-tray is honoured only when there **is** a tray. The setting says
  /// where the user wants the window to go; [_trayIconApplied] says whether
  /// that place exists. Hiding without it is not close-to-tray, it is a window
  /// that cannot be reopened.
  @override
  void onWindowClose() {
    if (_closeToTray && _trayIconApplied) {
      unawaited(_native.window.hide());
    } else {
      unawaited(_quit());
    }
  }

  @override
  void onWindowFocus() {
    _container.read(windowFocusedProvider.notifier).set(true);
    // The retry tick. See [retryOutstanding].
    unawaited(retryOutstanding());
  }

  @override
  void onWindowBlur() {
    // Notifications only fire while the window is unfocused, so this is the
    // signal that opens that gate.
    _container.read(windowFocusedProvider.notifier).set(false);
  }

  @override
  void onWindowResized() => unawaited(_saveWindowSize());

  Future<void> _saveWindowSize() async {
    try {
      final size = await _native.window.getSize();
      if (size.width < 200 || size.height < 200) return;
      _controller.setWindowSize(size.width, size.height);
    } on Object catch (error) {
      _logger.warning('system: reading the window size failed reason=$error');
    }
  }
}
