/// Where a file pulled off a device is put so this computer can paste it.
///
/// ## The whole reason this is a function and not `p.join` at the call site
///
/// A device id **is not serial-shaped**. Over Wi-Fi adb reports either
/// `192.168.1.24:37129` or
/// `adb-2B071FDH300JJ9-zcg43M._adb-tls-connect._tcp` — both shapes occur for
/// one phone depending on how adb reached it — and on Windows a colon in a
/// filename does not fail. It opens an **alternate data stream**: `adb pull`
/// writes to a stream hanging off a truncated name, every step reports
/// success, and the read-back finds an empty file. So every host path built
/// from a device id goes through [DeviceTarget.fileSafeId], and putting that
/// rule in one function is how it stays true — see `fileSafeDeviceId` in
/// `domain/device_target.dart`.
///
/// ## Why a staging directory at all
///
/// A file clipboard holds *paths*, so "copy this off the phone and paste it in
/// Explorer" needs a real file on this disk before the clipboard can name it.
/// The system temp directory is the honest place for it: the user did not ask
/// for a file anywhere in particular, and one that appeared beside their
/// documents without being asked for would be worse than one the OS cleans up.
/// The pane says where it went, so nothing is hidden.
library;

import 'package:path/path.dart' as p;

import '../domain/device_target.dart';

/// The directory under [temporaryDirectory] that holds files staged off
/// [target].
///
/// One directory per device — a file pulled from two phones with the same name
/// must not collide — and its name is [DeviceTarget.fileSafeId], never
/// [DeviceTarget.id].
String deviceStagingDirectory({
  required DeviceTarget target,
  required String temporaryDirectory,
}) => p.join(temporaryDirectory, kDeviceStagingFolder, target.fileSafeId);

/// Where one file staged off [target] lands.
///
/// [name] is the device-side basename and is used verbatim: it came from the
/// device's own listing, and rewriting it would hand the user a file whose
/// name is not the one they copied. A device filename that is illegal on
/// Windows fails at the pull, loudly, which is the right place for it.
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
