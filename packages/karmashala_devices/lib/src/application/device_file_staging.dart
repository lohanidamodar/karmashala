/// Where a file pulled off a device is put so this computer can paste it.
///
/// A device id **is not serial-shaped** — over Wi-Fi adb reports
/// `192.168.1.24:37129` — and on Windows a colon opens an **alternate data
/// stream**: every step reports success and the read-back finds an empty file.
/// So every host path built from a device id goes through
/// [DeviceTarget.fileSafeId], and this function is where that stays true.
library;

import 'package:path/path.dart' as p;

import '../domain/device_target.dart';

/// The directory under [temporaryDirectory] that holds files staged off
/// [target]. One per device, named by [DeviceTarget.fileSafeId], never by [id].
String deviceStagingDirectory({
  required DeviceTarget target,
  required String temporaryDirectory,
}) => p.join(temporaryDirectory, kDeviceStagingFolder, target.fileSafeId);

/// Where one file staged off [target] lands. [name] is the device-side basename,
/// used verbatim: rewriting it hands the user a file they did not copy.
String deviceStagedFilePath({
  required DeviceTarget target,
  required String temporaryDirectory,
  required String name,
}) => p.join(
  deviceStagingDirectory(
    target: target,
    temporaryDirectory: temporaryDirectory,
  ),
  name,
);

/// The one folder name every staged file lives under, so a sweep has something
/// to match on and a user has something to recognise.
const String kDeviceStagingFolder = 'karmashala-device-files';
