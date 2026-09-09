/// Driving an Android device or an iOS simulator from a desktop.
///
/// `devices.dart` is the whole vocabulary and every driver; import that, or
/// this, which adds the two policies that sit just above them:
///
/// * `DeviceFileStaging` — where a file pulled off a device is put, and what it
///   is called once two devices have a `screenshot.png`;
/// * `StreamRestartPolicy` — whether a mirror that just died should be dialled
///   again, and how long to wait first.
///
/// Both are decisions rather than drivers, which is why they were in the app's
/// `application/` layer; neither reaches a provider, so they travel with the
/// code they decide about.
library;

export 'devices.dart';
export 'src/application/device_file_staging.dart';
export 'src/application/stream_restart_policy.dart';
