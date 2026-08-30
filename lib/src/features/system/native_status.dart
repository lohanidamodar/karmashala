import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One OS-level thing a user setting asks for.
///
/// Each of these is a separate platform call that can fail on its own, so each
/// gets its own answer. "Launch at login is on" and "the registry write
/// succeeded" are different facts, and the settings screen was showing the
/// first while meaning the second.
enum NativeSetting {
  keepAwake,
  closeToTray,
  autoStart,
  launcherHotkey,
  trayIcon,
  trayMenu;

  /// How the settings screen names this when it has to say it failed.
  String get label => switch (this) {
    NativeSetting.keepAwake => 'keep awake',
    NativeSetting.closeToTray => 'close to tray',
    NativeSetting.autoStart => 'start at login',
    NativeSetting.launcherHotkey => 'hotkey registration',
    NativeSetting.trayIcon => 'the tray icon',
    NativeSetting.trayMenu => 'the tray menu',
  };
}

/// Whether the OS actually did what a setting asked, and why not.
@immutable
class NativeSettingStatus {
  const NativeSettingStatus.applied()
    : ok = true,
      reason = null,
      attempts = 0,
      exhausted = false;

  const NativeSettingStatus.failed(
    String this.reason, {
    required this.attempts,
    required this.exhausted,
  }) : ok = false;

  /// Whether the last attempt succeeded.
  final bool ok;

  /// The platform error, as it was reported.
  final String? reason;

  /// How many times this has been tried for the currently desired value.
  final int attempts;

  /// Whether the retry budget is spent. A setting that is merely *failing* will
  /// be tried again on the next settings change or window focus; an exhausted
  /// one waits for the user to change something.
  final bool exhausted;

  /// The line a settings row shows beside its toggle, or `null` when the OS
  /// agreed.
  ///
  /// [enabled] is the toggle's current position, because turning a setting
  /// *off* is a platform call that can fail too, and "enabled — close to tray
  /// failed" beside a switch that is off would be a second wrong answer on top
  /// of the first.
  String? messageFor(NativeSetting setting, {bool enabled = true}) => ok
      ? null
      : '${enabled ? 'enabled' : 'disabled'} — ${setting.label} '
            'failed: $reason';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeSettingStatus &&
          other.ok == ok &&
          other.reason == reason &&
          other.attempts == attempts &&
          other.exhausted == exhausted;

  @override
  int get hashCode => Object.hash(ok, reason, attempts, exhausted);

  @override
  String toString() => ok
      ? 'applied'
      : 'failed after $attempts (exhausted: $exhausted): $reason';
}

/// Per-setting native state, written by `SystemIntegrationService`.
///
/// Only failures and recoveries are recorded, so a settings screen watching
/// this does not rebuild every time a tray menu is refreshed with the same
/// result.
class NativeIntegrationStatusController
    extends Notifier<Map<NativeSetting, NativeSettingStatus>> {
  @override
  Map<NativeSetting, NativeSettingStatus> build() => const {};

  void record(NativeSetting setting, NativeSettingStatus status) {
    if (state[setting] == status) return;
    state = {...state, setting: status};
  }

  void clear() {
    if (state.isNotEmpty) state = const {};
  }
}

final nativeIntegrationStatusProvider =
    NotifierProvider<
      NativeIntegrationStatusController,
      Map<NativeSetting, NativeSettingStatus>
    >(NativeIntegrationStatusController.new);
