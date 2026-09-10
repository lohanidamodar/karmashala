import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/media/video_support_provider.dart';
import '../../../core/paths/app_support_directory.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../sessions/application/session_providers.dart';
import '../../settings/application/settings_controller.dart';

/// What the app fills into `karmashala_devices`'s seven ports. Installed once,
/// on the root container: every default the package ships is honest on its
/// own, so a container without these still works — it just uses this
/// machine's clock, no SSH, a temp folder and preferences it forgets.
final deviceBindings = [
  deviceClockProvider.overrideWith((ref) => ref.watch(clockProvider)),
  deviceCommandRunnerFactoryProvider.overrideWith(
    (ref) => ref.watch(commandRunnerFactoryProvider),
  ),
  deviceDataDirectoryProvider.overrideWithValue(appSupportDirectory),
  deviceVideoSupportProvider.overrideWith(
    (ref) => ref.watch(videoSupportProvider),
  ),
  deviceSlimmingPreferencesProvider.overrideWith(SettingsSlimmingPreferences.new),
  deviceClaimsProvider.overrideWith(
    (ref) => DeviceClaims(
      clock: ref.watch(clockProvider),
      holder: (sessionId) {
        final session = ref.read(sessionDaoProvider).getById(sessionId);
        if (session == null || session.isOver) return null;
        return session.title;
      },
    ),
  ),
  devicePathRevealerProvider.overrideWith(
    (ref) => _ShellPathRevealer(ref.watch(revealInFileManagerProvider)),
  ),
];

/// The slimming preferences as the app keeps them: projected out of settings
/// field by field, so a change to an unrelated setting rebuilds this notifier
/// but changes none of the values a surface selects.
class SettingsSlimmingPreferences extends DeviceSlimmingPreferences {
  @override
  DeviceSlimmingState build() => DeviceSlimmingState(
    androidSlimming: ref.watch(
      settingsControllerProvider.select((s) => s.androidSlimming),
    ),
    androidSlimmingEnabled: ref.watch(
      settingsControllerProvider.select((s) => s.androidSlimmingEnabled),
    ),
    androidEmulatorGpu: ref.watch(
      settingsControllerProvider.select((s) => s.androidEmulatorGpu),
    ),
    simulatorSlimming: ref.watch(
      settingsControllerProvider.select((s) => s.simulatorSlimming),
    ),
    simulatorSlimmingKept: ref.watch(
      settingsControllerProvider.select((s) => s.simulatorSlimmingKept),
    ),
  );

  SettingsController get _settings =>
      ref.read(settingsControllerProvider.notifier);

  @override
  void setAndroidSlimming(bool value) => _settings.setAndroidSlimming(value);

  @override
  void setAndroidSlimmingEnabled(List<String> ids) =>
      _settings.setAndroidSlimmingEnabled(ids);

  @override
  void setAndroidEmulatorGpu(String id) => _settings.setAndroidEmulatorGpu(id);

  @override
  void setSimulatorSlimming(bool value) =>
      _settings.setSimulatorSlimming(value);

  @override
  void setSimulatorSlimmingKept(List<String> ids) =>
      _settings.setSimulatorSlimmingKept(ids);
}

/// The shell's revealer as the package's port: the two answers differ only in
/// how a failure is carried.
class _ShellPathRevealer implements DevicePathRevealer {
  const _ShellPathRevealer(this._shell);

  final RevealInFileManager _shell;

  @override
  bool canReveal(EnvironmentPath path) => _shell.canReveal(path);

  @override
  Future<String?> reveal(EnvironmentPath path, {bool select = false}) async =>
      (await _shell.reveal(path, select: select)).error;
}
