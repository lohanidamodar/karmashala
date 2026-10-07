import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/shell/quick_open/quick_open.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart'
    show exitAfterSocketsSettle, settleUnixSockets;
import '../../core/lifecycle/app_lifecycle.dart';
import '../../core/lifecycle/before_quit.dart';
import '../../core/probe/probe_mode.dart';
import '../notifications/application/attention_inbox.dart';
import '../server/application/server_commands.dart';
import '../server/application/server_overview.dart';
import '../notifications/application/needs_you_chime.dart';
import '../notifications/application/notification_providers.dart';
import '../notifications/application/focus_mode.dart';
import '../notifications/presentation/notify_level_text.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_terminal_runtime/instances.dart'
    show TerminalViewGate, terminalViewGate;
import '../settings/application/settings_controller.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import '../settings/domain/settings.dart';
import 'launcher_hotkey.dart';
import 'native_adapters.dart';
import 'native_status.dart';

const _kMenuShow = 'show';
const _kMenuHide = 'hide';
const _kMenuKeepAwake = 'keep_awake';
const _kMenuNotifyPrefix = 'notify_';
const _kMenuFocus = 'focus';
const _kMenuOnlyWhenUnfocused = 'notifications_unfocused';
const _kMenuQuit = 'quit';
const _kMenuServerSettings = 'server_settings';

/// Prefix for the Server section's commands; the suffix is a [ServerCommand]'s
/// name.
const _kMenuServerPrefix = 'server:';

/// Where `applicationShouldTerminate` asks Dart to quit. See `AppDelegate`.
const MethodChannel _lifecycleChannel = MethodChannel('karmashala/lifecycle');

/// Installs [quit] as what the OS's Quit runs.
typedef OsQuitRegistrar = void Function(Future<void> Function() quit);

/// The real one: macOS's `applicationShouldTerminate` cancels its own
/// termination and calls `quitRequested` here instead, so Cmd+Q and logout get
/// the same ordered shutdown as the tray's Quit. Any engine exit request is
/// routed there too.
void registerOsQuitOverChannel(Future<void> Function() quit) {
  if (Platform.isMacOS) {
    _lifecycleChannel.setMethodCallHandler((call) async {
      if (call.method == 'quitRequested') unawaited(quit());
    });
  }
  _exitRequests?.dispose();
  _exitRequests = listenForExitRequests(quit);
}

AppLifecycleListener? _exitRequests;

/// Answers a cancelable exit the engine asks the framework about by running
/// [quit] instead, which asks, flushes and ends the process itself.
AppLifecycleListener listenForExitRequests(Future<void> Function() quit) =>
    AppLifecycleListener(
      onExitRequested: () async {
        unawaited(quit());
        return AppExitResponse.cancel;
      },
    );

/// Prefix for the per-session "needs you" items; the suffix is the index into
/// [SystemIntegrationService._pending].
const _kMenuAttentionPrefix = 'attention:';

/// The tray icons, in the format the host tray can decode: Windows wants a
/// multi-size `.ico`, and macOS and Linux draw nothing at all from one.
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
/// stops. The common failure — another app owns the chord — never resolves.
const _kMaxNativeAttempts = 4;

Future<void> _noShutdown() async {}

/// Wires the desktop OS integrations to the user [Settings]. **Desired versus
/// applied**: an applied marker is written only after the platform call returns.
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
    void Function()? endProcess,
    Future<void> Function()? settleSockets,
    TerminalViewGate? terminalViews,
  }) : _native = adapters ?? NativeAdapters.platform(),
       _terminalViews = terminalViews ?? terminalViewGate,
       _logger = logger ?? AppLogger.named('system'),
       _onQuitRequested = onQuitRequested ?? _noShutdown,
       _registerOsQuit = registerOsQuit ?? registerOsQuitOverChannel,
       _endProcess = endProcess ?? _exitProcess,
       _socketSettler = settleSockets;

  static void _exitProcess() => unawaited(exitAfterSocketsSettle(0));

  /// Closes this process's unix sockets in order before the window goes
  /// ([settleUnixSockets] when null). A seam like [_endProcess].
  final Future<void> Function()? _socketSettler;

  /// Ends the process, once the ordered shutdown has run and the window is
  /// gone. A seam so tests can exercise quitting without taking the test
  /// runner down with it.
  final void Function() _endProcess;

  /// How the OS's own Quit reaches this service. A seam, because a
  /// `MethodChannel` cannot even be handed a handler without a Flutter binding.
  final OsQuitRegistrar _registerOsQuit;

  /// The current server session's container; [rebind] moves it to the next
  /// one, so the tray and hotkeys outlive a change of server.
  ProviderContainer _container;

  /// What [_listenToContainer] listens with, closed on [rebind].
  final List<ProviderSubscription<Object?>> _subscriptions = [];

  final NativeAdapters _native;
  final TerminalViewGate _terminalViews;
  final AppLogger _logger;

  /// Runs before the window is destroyed, so the lifecycle owner can shut the
  /// rest of the app down in order. A no-op outside the app (tests, tools).
  final Future<void> Function() _onQuitRequested;

  /// Whether closing the window hides to the tray instead of quitting. Read by
  /// [onWindowClose] and nothing else; prevent-close is *not* derived from it.
  bool _closeToTray = false;

  /// Whether the tray icon actually went up. Hiding to a tray that is not there
  /// is a window the user cannot get back — stock GNOME, or Wayland.
  bool _trayIconApplied = false;
  bool _disposed = false;

  /// Between a server switch's [detach] and its [rebind]: [_container] is
  /// closed, so every tray, hotkey and window event that would read it is
  /// dropped (plan step 14); showing the window and Quit still act.
  bool _detached = false;

  /// Whether [_container] may be read: neither disposed nor between servers.
  bool get _bound => !_disposed && !_detached;

  /// What the window events last said; either one suspends [_terminalViews].
  bool _minimized = false;
  bool _hiddenToTray = false;

  /// Set the moment quitting begins, and never cleared. Quitting is re-entrant
  /// on macOS, and the two passes bounce off each other forever without this.
  bool _quitting = false;

  /// While the before-quit guards are asking; a second quit meanwhile is dropped.
  bool _confirmingQuit = false;

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

  /// What the attention inbox has that the user has not seen, as the tray shows
  /// it. The *inbox*, not the raw attention set: one list, one count.
  List<InboxItem> _pending = const [];

  /// The tooltip last set, so the native calls only happen when what it says
  /// actually moved. Null forces the first apply.
  String? _appliedToolTip;

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// A probe registers nothing machine-wide: launch-at-login is one registry
  /// value named `Karmashala`, shared with the real app, and so is the chord.
  /// Read once: a probe is the process's, whichever server it is a client
  /// of, and the container may be closed when it is next asked.
  late final bool _probe = _container.read(probeModeProvider).enabled;

  String get _appLabel => _probe ? 'Karmashala PROBE' : 'Karmashala';

  Settings get _settings => _container.read(settingsControllerProvider);
  SettingsController get _controller =>
      _container.read(settingsControllerProvider.notifier);

  /// Initializes the tray and window integration, applies the current settings
  /// and listens. Each step is independent, and what failed is recorded.
  Future<void> init() async {
    if (!isSupported) return;

    if (_probe) {
      _logger.info('system: probe — no launch-at-login, no global hotkey.');
    } else {
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
    }

    _native.window.addListener(this);
    _native.tray.addListener(this);

    // Clear any stale system hotkeys left registered by a previous run/crash
    // before we register ours (recommended by hotkey_manager).
    if (!_probe) {
      try {
        await _native.hotkey.unregisterAll();
      } on Object catch (error, stack) {
        _logger.warning(
          'system: clearing stale hotkeys failed reason=$error',
          error,
          stack,
        );
      }
    }

    // macOS routes Cmd+Q here rather than terminating, so the same ordered
    // shutdown runs for it. Without this the app menu's Quit was swallowed.
    _registerOsQuit(() => _quit());

    _trayIconApplied = await _run(NativeSetting.trayIcon, () async {
      await _native.tray.setIcon(_kIdleTrayIcon);
      await _native.tray.setToolTip(_appLabel);
    });

    await apply(_settings);

    _listenToContainer();
  }

  /// Moves this service onto [next], the container of a newly opened server
  /// session: the old container's listeners end, the new one's settings are
  /// applied and followed. The tray, the window listeners, the hotkey and the
  /// OS quit stay registered — they are the process's, not the server's.
  /// A switch of server calls it once the next session is open, [detach]
  /// having let go of the old one.
  Future<void> rebind(ProviderContainer next) async {
    if (_disposed) return;
    if (identical(next, _container) && !_detached) return;
    _closeSubscriptions();
    _container = next;
    _detached = false;
    _appliedToolTip = null;
    _pending = const [];
    _container.read(systemIntegrationProvider.notifier).adopt(this);
    if (!isSupported) return;
    // The new container starts out believing the window is focused; say what
    // it is, so a toast's "only when unfocused" gate is right from the start.
    try {
      final focused = await _native.window.isFocused();
      if (_bound) _container.read(windowFocusedProvider.notifier).set(focused);
    } on Object catch (error) {
      _logger.warning('system: reading the window focus failed reason=$error');
    }
    await apply(_settings);
    _listenToContainer();
  }

  /// Lets go of the current container before its server session closes (a
  /// switch of server, plan step 14): its listeners end, and until [rebind]
  /// no event reads it. The tray, the hotkey, the window listeners and the OS
  /// quit stay registered.
  void detach() {
    if (!_bound) return;
    _detached = true;
    _closeSubscriptions();
    _pending = const [];
  }

  void _closeSubscriptions() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    _subscriptions.clear();
  }

  void _listenToContainer() {
    _subscriptions.add(
      _container.listen<Settings>(
        settingsControllerProvider,
        (_, next) => unawaited(apply(next)),
      ),
    );

    // Agent status → tray. The icon and menu are ambient state, so they follow
    // what needs the user regardless of focus; the interrupting half (toasts)
    // is the dispatcher's job, behind the policy.
    _subscriptions.add(
      _container.listen<AttentionInbox>(
        attentionInboxProvider,
        (_, next) => unawaited(_applyAttention(next)),
      ),
    );
    _subscriptions.add(
      _container.listen<NotificationSettings>(
        notificationSettingsControllerProvider,
        (_, _) => unawaited(_refreshMenu(_settings)),
      ),
    );
    _subscriptions.add(
      // Immediately too: it may have been read while [apply] drew the menu.
      _container.listen<AsyncValue<ServerOverview>>(
        serverOverviewProvider,
        (_, _) => unawaited(_refreshMenu(_settings)),
        fireImmediately: true,
      ),
    );
    // A clicked toast asks for the window, from outside the widget tree.
    _subscriptions.add(
      _container.listen<int>(
        windowRaiseRequestProvider,
        (_, _) => unawaited(_raiseWindow()),
      ),
    );

    _container.read(attentionPresenterProvider).start();
    _container.read(needsYouChimeProvider);
  }

  /// Applies [settings] to the OS. Prevent-close is the one value here that is
  /// **not** a setting: without it `WM_CLOSE` never reaches Dart at all.
  Future<void> apply(Settings settings) async {
    if (!_bound) return;
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

    // Never reconciled in a probe: a fresh probe database says "off", and
    // applying that would delete the real app's launch-at-login entry.
    if (_probe) return;

    if (_desiredAutoStart != _appliedAutoStart &&
        _hasBudget(NativeSetting.autoStart)) {
      await _applyAutoStart(_desiredAutoStart!);
    }

    if (_desiredHotkeySignature != _appliedHotkeySignature &&
        _hasBudget(NativeSetting.launcherHotkey)) {
      await _applyLauncherHotkey(settings);
    }
  }

  /// Retries whatever the OS has not confirmed yet. Window focus is the cheap,
  /// well-timed signal: the conditions that fail these change in the background.
  Future<void> retryOutstanding() async {
    if (!_bound || !isSupported) return;
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

  /// Publishes one setting's native state. A call still in flight at shutdown
  /// would otherwise land on a disposed container.
  void _record(NativeSetting setting, NativeSettingStatus status) {
    if (!_bound) return;
    try {
      _container
          .read(nativeIntegrationStatusProvider.notifier)
          .record(setting, status);
    } on Object catch (error) {
      _logger.warning('system: could not publish native status: $error');
    }
  }

  /// Registers (or clears) the global launcher hotkey. The signature is written
  /// **after** registration returns, so a held chord is retried, not recorded.
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

  /// Global-hotkey handler: a summon/dismiss toggle for the whole app. Quick
  /// open replaced the second mini-launcher window this used to raise.
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
    if (_bound) _container.read(quickOpenRequestProvider.notifier).bump();
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
    if (!_bound) return;
    _pending = inbox.pending;
    // "Need you" is the asks alone, seen or not, as the strip's Inbox badge
    // counts them (inboxAskCountProvider); an unseen finished turn is news,
    // said separately, never claimed as needing the user.
    var asks = 0;
    for (final item in inbox.items) {
      if (item.kind == InboxItemKind.needsApproval) asks++;
    }
    var updates = 0;
    for (final item in inbox.pending) {
      if (item.kind != InboxItemKind.needsApproval) updates++;
    }
    final toolTip = _toolTip(asks, updates);
    if (toolTip != _appliedToolTip) {
      final wasBadged = _appliedToolTip != null && _appliedToolTip != _appLabel;
      final isBadged = toolTip != _appLabel;
      _appliedToolTip = toolTip;
      await _run(NativeSetting.trayIcon, () async {
        if (wasBadged != isBadged) {
          await _native.tray.setIcon(
            isBadged ? _kAttentionTrayIcon : _kIdleTrayIcon,
          );
        }
        await _native.tray.setToolTip(toolTip);
      });
    }
    await _refreshMenu(_settings);
  }

  /// "Karmashala — 2 need you · 3 new updates"; either half only when it
  /// has something to say, and the bare name when neither does.
  String _toolTip(int asks, int updates) {
    final parts = [
      if (asks > 0) '$asks need${asks == 1 ? 's' : ''} you',
      if (updates > 0) '$updates new update${updates == 1 ? '' : 's'}',
    ];
    return parts.isEmpty ? _appLabel : '$_appLabel — ${parts.join(' · ')}';
  }

  Future<void> _refreshMenu(Settings settings) async {
    if (!_bound) return;
    final notifications = _container.read(
      notificationSettingsControllerProvider,
    );
    await _run(
      NativeSetting.trayMenu,
      () => _native.tray.setContextMenu(
        TrayMenu([
          ..._attentionMenuItems(),
          const TrayMenuItem.separator(),
          const TrayMenuItem(key: _kMenuShow, label: 'Open Karmashala'),
          const TrayMenuItem(key: _kMenuHide, label: 'Hide window'),
          const TrayMenuItem.separator(),
          ..._serverMenuItems(),
          const TrayMenuItem.separator(),
          TrayMenuItem.checkbox(
            key: _kMenuKeepAwake,
            label: 'Keep system awake',
            checked: settings.keepAwake,
          ),
          TrayMenuItem.checkbox(
            key: _kMenuFocus,
            label: 'Focus',
            checked: notifications.focus != null,
          ),
          for (final level in NotifyLevel.values)
            TrayMenuItem.checkbox(
              key: '$_kMenuNotifyPrefix${level.name}',
              label: 'Notify me: ${notifyLevelLabel(level)}',
              checked: notifications.level == level,
            ),
          TrayMenuItem.checkbox(
            key: _kMenuOnlyWhenUnfocused,
            label: 'Only when the window is not focused',
            checked: notifications.onlyWhenUnfocused,
            disabled: !notifications.enabled,
          ),
          const TrayMenuItem.separator(),
          const TrayMenuItem(key: _kMenuQuit, label: 'Quit'),
        ]),
      ),
    );
  }

  /// The "needs you" section: one clickable item per waiting session, or a
  /// disabled line when nothing does — an empty tray menu reads as broken.
  List<TrayMenuItem> _attentionMenuItems() {
    if (_pending.isEmpty) {
      return const [
        TrayMenuItem(
          key: 'attention_none',
          label: 'Nothing needs you',
          disabled: true,
        ),
      ];
    }
    final shown = _pending.take(_kMaxAttentionItems).toList();
    return [
      for (var i = 0; i < shown.length; i++)
        TrayMenuItem(
          key: '$_kMenuAttentionPrefix$i',
          label: shown[i].menuLabel,
        ),
      if (_pending.length > shown.length)
        TrayMenuItem(
          key: 'attention_more',
          label: '+${_pending.length - shown.length} more',
          disabled: true,
        ),
    ];
  }

  /// "Server: running · 3 sessions", then the commands its state takes — none
  /// while this window uses another machine's server — and its Settings page.
  List<TrayMenuItem> _serverMenuItems() {
    final overview = _container.read(serverOverviewProvider).value;
    return [
      TrayMenuItem(
        key: 'server_status',
        label: describeServerLine(overview),
        disabled: true,
      ),
      for (final command in serverCommandsFor(overview))
        TrayMenuItem(
          key: '$_kMenuServerPrefix${command.name}',
          label: command.label,
        ),
      const TrayMenuItem(
        key: _kMenuServerSettings,
        label: 'Open Server settings',
      ),
    ];
  }

  /// Runs a Server section item through the shell, which holds the Settings
  /// page's confirm; the window comes forward first for anything it shows,
  /// out of the tray if it was hidden there.
  void _serverMenuItem(String key) {
    final requests = _container.read(serverCommandRequestProvider.notifier);
    if (key == _kMenuServerSettings) {
      unawaited(_raiseWindow());
      requests.openSettings();
      return;
    }
    final name = key.substring(_kMenuServerPrefix.length);
    final command = ServerCommand.values.firstWhere((c) => c.name == name);
    if (command != ServerCommand.start) unawaited(_raiseWindow());
    requests.ask(command);
  }

  /// Brings the app forward on the session behind tray item [index].
  void _openAttention(int index) {
    if (!_bound || index < 0 || index >= _pending.length) return;
    // Through the inbox, so opening from the tray marks the item seen and the
    // tray badge and the activity strip's badges all drop by one together.
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
      _logger.info(
        'system: tray toggle → ${visible && focused ? 'hide' : 'show'} '
        '(visible=$visible focused=$focused)',
      );
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

  /// Quits the application: before-quit guards and flushes, layout snapshot,
  /// ordered shutdown, window destroyed, process ended. The one graceful exit,
  /// and it runs at most once per launch — unless a guard cancels it.
  Future<void> quit() => _quit();

  Future<void> _quit() async {
    if (_quitting) return;
    if (_confirmingQuit) {
      // Asked again while a question is up: it may be behind a hidden window.
      unawaited(_showWindow());
      return;
    }
    final hooks = _beforeQuitHooks();
    if (hooks != null) {
      _confirmingQuit = true;
      final bool proceed;
      try {
        proceed = await hooks.confirm();
      } finally {
        _confirmingQuit = false;
      }
      if (!proceed || _quitting) return;
    }
    _quitting = true;
    await hooks?.flush();
    _saveTerminalLayout();
    try {
      await _onQuitRequested();
    } on Object catch (error, stack) {
      // A shutdown step that fails must not strand the user in an app that
      // will not close.
      _logger.warning('system: shutdown before quit failed.', error, stack);
    }
    // Before the window: destroying it can end the process on Windows, and an
    // exit with a unix socket's close pending bugchecks the machine.
    try {
      await (_socketSettler?.call() ??
          settleUnixSockets(log: _logger.info).then((_) {}));
    } on Object catch (error) {
      _logger.warning('system: settling unix sockets failed reason=$error');
    }
    // Bracketed, and the two lines are the whole diagnosis for a quit that never
    // finishes: on stdout they are unbuffered, so a missing second line locates it.
    _logger.info('system: shutdown done; destroying the window.');
    try {
      await _native.window.setPreventCloseAndDestroy();
      _logger.info('system: window destroyed.');
    } on Object catch (error) {
      _logger.warning('system: window destroy failed reason=$error');
    }
    // Last before the process ends: everything above logged after `shutdown()`'s
    // own flush, and the sink's 400 ms timer is a task for an isolate about to stop.
    await _flushLog();
    // Destroying the window does not end the process: `applicationShouldTerminate`
    // cancels AppKit's termination so this shutdown can run at all.
    _endProcess();
  }

  BeforeQuitHooks? _beforeQuitHooks() {
    // Between servers: the old session's guards went with it.
    if (!_bound) return null;
    try {
      return _container.read(beforeQuitHooksProvider);
    } on Object catch (error) {
      // A container already gone has nothing left to flush.
      _logger.warning('system: before-quit hooks unavailable reason=$error');
      return null;
    }
  }

  /// Writes the queued log lines to disk, bounded, before the process ends —
  /// `LogFileSink`'s 400 ms timer is a task for the isolate that is stopping.
  Future<void> _flushLog() async {
    try {
      await Diagnostics.instance.flushFile().timeout(kLogFlushBudget);
    } on Object {
      // Nowhere left to report it, and a sink that will not write must not be
      // what keeps the app open.
    }
  }

  /// Snapshots the terminal layout on the way out: first, synchronously, before
  /// anything can fail. Guarded so quitting never *creates* the controller.
  void _saveTerminalLayout() {
    // Between servers: the switch saved the old server's layout on its way.
    if (!_bound) return;
    try {
      if (!_container.exists(terminalSessionsControllerProvider)) return;
      // persistLayout, not persistStructure: this is the last write before
      // the process ends, so it has to re-encode every pane the structural
      // saves left for the autosave. It covers the autosave too.
      _container
          .read(terminalSessionsControllerProvider.notifier)
          .persistLayout();
    } on Object catch (error) {
      // Never block quitting on persistence.
      _logger.warning('system: persisting the layout failed reason=$error');
    }
  }

  /// Detaches from the OS. Ordered so the app stops *receiving* events before it
  /// stops being able to answer them; every step is independent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _terminalViews.resume();
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
  void onTrayIconClicked() {
    _logger.info('system: tray icon clicked');
    unawaited(_toggleWindow());
  }

  @override
  void onTrayIconRightClicked() => unawaited(_native.tray.popUpContextMenu());

  @override
  void onTrayMenuItemClicked(String key) {
    if (key.startsWith(_kMenuAttentionPrefix)) {
      final index = int.tryParse(key.substring(_kMenuAttentionPrefix.length));
      if (index != null) _openAttention(index);
      return;
    }
    switch (key) {
      case _kMenuShow:
        unawaited(_showWindow());
      case _kMenuHide:
        unawaited(_native.window.hide());
      case _kMenuQuit:
        unawaited(_quit());
      // The rest are the server's settings: nothing to change between servers.
      case _ when !_bound:
        return;
      case _kMenuServerSettings:
      case _ when key.startsWith(_kMenuServerPrefix):
        _serverMenuItem(key);
      case _kMenuKeepAwake:
        _controller.setKeepAwake(!_settings.keepAwake);
      case _kMenuFocus:
        _container.read(focusModeProvider.notifier).toggle();
      case _ when key.startsWith(_kMenuNotifyPrefix):
        final name = key.substring(_kMenuNotifyPrefix.length);
        for (final level in NotifyLevel.values) {
          if (level.name != name) continue;
          _container
              .read(notificationSettingsControllerProvider.notifier)
              .setLevel(level);
        }
      case _kMenuOnlyWhenUnfocused:
        final notifications = _container.read(
          notificationSettingsControllerProvider.notifier,
        );
        notifications.setOnlyWhenUnfocused(
          !_container
              .read(notificationSettingsControllerProvider)
              .onlyWhenUnfocused,
        );
    }
  }

  // --- WindowListener ---

  /// The window's X, reached only because prevent-close is on. Close-to-tray is
  /// honoured only when there **is** a tray — otherwise it cannot be reopened.
  @override
  void onWindowClose() {
    final hide = _closeToTray && _trayIconApplied;
    // Logged because the two ways this can go look identical from outside: a
    // close that quits is either the setting off or the icon never having gone up.
    _logger.info(
      'system: window close → ${hide ? 'hide to tray' : 'quit'} '
      '(closeToTray=$_closeToTray trayIcon=$_trayIconApplied)',
    );
    if (hide) {
      unawaited(_native.window.hide());
    } else {
      unawaited(_quit());
    }
  }

  /// Terminals stop repainting while nobody can see them. Flutter reports only
  /// `inactive` when minimized here, so the window events decide. A focus while
  /// minimized reopens nothing.
  @override
  void onWindowEvent(String eventName) {
    switch (eventName) {
      case kWindowEventMinimize:
        _minimized = true;
      case kWindowEventRestore ||
          kWindowEventMaximize ||
          kWindowEventUnmaximize:
        _minimized = false;
      case 'hide':
        _hiddenToTray = true;
      case 'show':
        _hiddenToTray = false;
      case kWindowEventFocus when !_minimized:
        _hiddenToTray = false;
      default:
        return;
    }
    if (_minimized || _hiddenToTray) {
      _terminalViews.suspend();
    } else {
      _terminalViews.resume();
    }
  }

  @override
  void onWindowFocus() {
    if (!_bound) return;
    _container.read(windowFocusedProvider.notifier).set(true);
    // The retry tick. See [retryOutstanding].
    unawaited(retryOutstanding());
  }

  @override
  void onWindowBlur() {
    // Notifications only fire while the window is unfocused, so this is the
    // signal that opens that gate.
    if (!_bound) return;
    _container.read(windowFocusedProvider.notifier).set(false);
  }

  @override
  void onWindowResized() => unawaited(_saveWindowSize());

  Future<void> _saveWindowSize() async {
    try {
      final size = await _native.window.getSize();
      if (!_bound || size.width < 200 || size.height < 200) return;
      _controller.setWindowSize(size.width, size.height);
    } on Object catch (error) {
      _logger.warning('system: reading the window size failed reason=$error');
    }
  }
}
