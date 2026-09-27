/// What this package needs from whoever hosts it. Every port has a default
/// that works on its own, so a surface mounted with no overrides gets
/// behaviour rather than a null; the app binds them together in one place.
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_media/media.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_devices/karmashala_devices.dart';

/// The clock every device reading is stamped with. The app overrides it with
/// its own, so a test that fixes the app's clock fixes this one too.
final deviceClockProvider = Provider<Clock>((ref) => const SystemClock());

/// The Android SDK a person named (`settings.v1`'s `androidSdkPath`), or null.
/// Tried first, by the same rule the server follows (`sdkCandidateRoots`), so
/// the pane and the server's tools reach one adb and one adb daemon.
final deviceAndroidSdkPathProvider = Provider<String?>((ref) => null);

/// Who holds each device, by id, as the server's claims last said (slice
/// 4a). The app fills it when its server runs on this machine — the pane's
/// devices are then the server's too; elsewhere nobody holds anything a pane
/// could be told about. A person's action on a held device asks first.
final deviceHoldersProvider = Provider<Map<String, DeviceClaim>>(
  (ref) => const {},
);

/// How an environment becomes a runner. The default reaches this machine and
/// a WSL distribution and refuses SSH in words; the app overrides it with the
/// SSH-aware factory, which is a composition over its own connection pool.
final deviceCommandRunnerFactoryProvider = Provider<CommandRunnerFactory>(
  (ref) => const CommandRunnerFactory(),
);

/// Where this app keeps per-user data; a recording goes in a folder under it.
/// The default is a fixed folder in temp, so a container that never says
/// where still writes somewhere real and never into a user's profile.
final deviceDataDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => () async {
    final directory = Directory(
      p.join(Directory.systemTemp.path, 'karmashala'),
    );
    await directory.create(recursive: true);
    return directory;
  },
);

/// What this host can write a video with. Measured once and then kept — an
/// installed encoder does not come and go.
/// The app asks for the hardware encoder; `flutter test` must not — see
/// [appHardwareTransforms].
final deviceVideoSupportProvider = Provider<VideoSupport>(
  (ref) => probeVideoSupport(hardwareTransforms: appHardwareTransforms),
);

/// The slimming preferences, as one value so a surface can `select` the single
/// field it draws and rebuild on that alone.
class DeviceSlimmingState {
  const DeviceSlimmingState({
    this.androidSlimming = false,
    this.androidSlimmingEnabled = const [],
    this.androidEmulatorGpu = '',
    this.simulatorSlimming = false,
    this.simulatorSlimmingKept = const [],
  });

  /// Whether starting an emulator slims it at all — the master switch.
  final bool androidSlimming;

  /// Ids of the Android categories to apply. An id that no longer names a
  /// category is dropped where it is read, not treated as an error.
  final List<String> androidSlimmingEnabled;

  /// Id of the renderer an emulator is started with.
  final String androidEmulatorGpu;

  /// Whether starting a simulator slims it.
  final bool simulatorSlimming;

  /// Ids of the simulator categories to leave running.
  final List<String> simulatorSlimmingKept;

  DeviceSlimmingState copyWith({
    bool? androidSlimming,
    List<String>? androidSlimmingEnabled,
    String? androidEmulatorGpu,
    bool? simulatorSlimming,
    List<String>? simulatorSlimmingKept,
  }) => DeviceSlimmingState(
    androidSlimming: androidSlimming ?? this.androidSlimming,
    androidSlimmingEnabled:
        androidSlimmingEnabled ?? this.androidSlimmingEnabled,
    androidEmulatorGpu: androidEmulatorGpu ?? this.androidEmulatorGpu,
    simulatorSlimming: simulatorSlimming ?? this.simulatorSlimming,
    simulatorSlimmingKept: simulatorSlimmingKept ?? this.simulatorSlimmingKept,
  );
}

/// Where the slimming preferences are kept. The app's implementation projects
/// them out of its settings and writes back through the same controller.
abstract class DeviceSlimmingPreferences extends Notifier<DeviceSlimmingState> {
  void setAndroidSlimming(bool value);
  void setAndroidSlimmingEnabled(List<String> ids);
  void setAndroidEmulatorGpu(String id);
  void setSimulatorSlimming(bool value);
  void setSimulatorSlimmingKept(List<String> ids);
}

/// The default: remembers inside one container and nowhere else.
class InMemorySlimmingPreferences extends DeviceSlimmingPreferences {
  @override
  DeviceSlimmingState build() =>
      DeviceSlimmingState(androidEmulatorGpu: AndroidGpuMode.auto.id);

  @override
  void setAndroidSlimming(bool value) =>
      state = state.copyWith(androidSlimming: value);

  @override
  void setAndroidSlimmingEnabled(List<String> ids) =>
      state = state.copyWith(androidSlimmingEnabled: ids);

  @override
  void setAndroidEmulatorGpu(String id) =>
      state = state.copyWith(androidEmulatorGpu: id);

  @override
  void setSimulatorSlimming(bool value) =>
      state = state.copyWith(simulatorSlimming: value);

  @override
  void setSimulatorSlimmingKept(List<String> ids) =>
      state = state.copyWith(simulatorSlimmingKept: ids);
}

/// The slimming preferences in effect. Read one field through `select`: this
/// notifier is rebuilt by any settings change, its fields are not.
final deviceSlimmingPreferencesProvider =
    NotifierProvider<DeviceSlimmingPreferences, DeviceSlimmingState>(
      InMemorySlimmingPreferences.new,
    );

/// Showing a pulled file or a finished recording where the user keeps their
/// files. The app's `RevealInFileManager` implements this; it resolves an
/// environment id through a DAO, which is why it cannot live here.
abstract interface class DevicePathRevealer {
  /// Whether [path] can be shown at all on this host. Cheap: no process is
  /// started, so a build may ask before offering the button.
  bool canReveal(EnvironmentPath path);

  /// Opens the host's file manager on [path], highlighting the entry when
  /// [select] and the platform can. Returns why it did not, or null.
  Future<String?> reveal(EnvironmentPath path, {bool select = false});
}

/// A revealer that can show nothing. The button asks before it offers itself,
/// so this default hides it rather than failing when pressed.
class NoPathRevealer implements DevicePathRevealer {
  const NoPathRevealer();

  @override
  bool canReveal(EnvironmentPath path) => false;

  @override
  Future<String?> reveal(EnvironmentPath path, {bool select = false}) async =>
      'This platform has no file manager Karmashala can open.';
}

/// How a device file or recording is shown in the host's file manager.
final devicePathRevealerProvider = Provider<DevicePathRevealer>(
  (ref) => const NoPathRevealer(),
);
