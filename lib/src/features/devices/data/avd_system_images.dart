/// Whether an AVD's system image is actually installed.
///
/// **`emulator -list-avds` is not evidence that an AVD can boot.** It lists
/// directories. On 2026-09-03 two of this machine's AVDs listed perfectly and
/// then died on launch with `PANIC: Cannot find AVD system path`, because the
/// system image their `config.ini` names had never been downloaded — and
/// nothing in the app could say so before the boot attempt burned three
/// minutes. The image is named in a file; reading it costs nothing.
///
/// Everything here is pure: paths in, path out. The existence checks belong to
/// the caller, which is what makes this testable without an SDK.
library;

/// Reads `key=value` out of an AVD `.ini` / `config.ini`.
///
/// These files are `key=value` per line with `#` comments; values are taken
/// verbatim after the first `=`, since a Windows path is full of characters a
/// cleverer parse would mangle.
String? iniValue(String content, String key) {
  for (final raw in content.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final split = line.indexOf('=');
    if (split <= 0) continue;
    if (line.substring(0, split).trim() != key) continue;
    final value = line.substring(split + 1).trim();
    return value.isEmpty ? null : value;
  }
  return null;
}

/// The `<name>.avd` directory an AVD's `<name>.ini` points at.
///
/// `path` is absolute and authoritative when present. `path.rel` is the
/// relative form Android Studio writes for a portable SDK home, resolved
/// against [avdHome]'s parent — the `.android` directory it names things from.
String? avdDirectory(
  String iniContent, {
  required String avdHome,
  required String separator,
}) {
  final absolute = iniValue(iniContent, 'path');
  if (absolute != null) return absolute;
  final relative = iniValue(iniContent, 'path.rel');
  if (relative == null) return null;
  final parent = _parentOf(avdHome, separator);
  final normalised = relative.replaceAll(RegExp(r'[\\/]'), separator);
  return _join(parent, normalised, separator);
}

/// The system-image directory an AVD's `config.ini` names, under [sdkRoot].
///
/// `image.sysdir.1` is stored with forward slashes and a trailing one
/// regardless of platform; both are normalised here so the result can be
/// handed straight to an existence check.
String? systemImageDirectory(
  String configContent, {
  required String sdkRoot,
  required String separator,
}) {
  final sysdir = iniValue(configContent, 'image.sysdir.1');
  if (sysdir == null) return null;
  final normalised = sysdir
      .replaceAll(RegExp(r'[\\/]+'), separator)
      .replaceAll(RegExp('${RegExp.escape(separator)}\$'), '');
  if (normalised.isEmpty) return null;
  return _join(sdkRoot, normalised, separator);
}

/// What an inspection found for one AVD.
class AvdImageStatus {
  const AvdImageStatus.installed(this.name, this.imagePath)
    : missingImage = false,
      problem = null;

  const AvdImageStatus.missingSystemImage(this.name, this.imagePath)
    : missingImage = true,
      problem = null;

  /// The AVD's own files could not be read, so nothing was learned about it.
  /// Deliberately not "broken": an unreadable `.ini` is our blind spot, not
  /// necessarily the AVD's fault.
  const AvdImageStatus.unknown(this.name, this.problem)
    : imagePath = null,
      missingImage = false;

  final String name;

  /// Where the system image was expected.
  final String? imagePath;

  /// The image directory is named and is not there — this AVD will panic.
  final bool missingImage;

  /// Why the check could not be completed, when it could not.
  final String? problem;

  bool get checked => problem == null;
}

String _parentOf(String path, String separator) {
  final trimmed = path.endsWith(separator)
      ? path.substring(0, path.length - separator.length)
      : path;
  final cut = trimmed.lastIndexOf(separator);
  return cut <= 0 ? trimmed : trimmed.substring(0, cut);
}

String _join(String left, String right, String separator) {
  final head = left.endsWith(separator)
      ? left.substring(0, left.length - separator.length)
      : left;
  final tail = right.startsWith(separator)
      ? right.substring(separator.length)
      : right;
  return '$head$separator$tail';
}
