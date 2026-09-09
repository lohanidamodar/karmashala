import 'dart:convert';

import 'vm_service_uri.dart';

/// The Dart Tooling Daemon, and what it will tell anyone who asks.
///
/// **This is the one reader that finds a run Karmashala did not start.** Every
/// `flutter run` starts a DDS, and a DDS with DevTools enabled — the default —
/// starts a DTD, which records itself in a file named after its pid. The
/// daemon then answers `ConnectedApp.getVmServices` with each attached app's
/// VM service URI, auth token included, and that call takes no secret.
///
/// Measured on the owner's machine 2026-09-09 against a `flutter run` started
/// from a plain terminal; the pid file and the reply are pinned verbatim in
/// `dtd_instance_test.dart`.
class DtdInstance {
  const DtdInstance({
    required this.pid,
    required this.wsUri,
    required this.workspaceRoot,
    required this.startedAt,
    this.dartVersion,
  });

  final int pid;

  /// The daemon's own address. Its path token is the only thing gating the VM
  /// service tokens behind it.
  final Uri wsUri;

  /// The directory the daemon was started in — the project, for a `flutter
  /// run`, which is how one daemon is told from another.
  final String workspaceRoot;

  final DateTime startedAt;
  final String? dartVersion;
}

/// One app a daemon knows about.
class DtdApp {
  const DtdApp({required this.uri, this.name});

  /// The VM service address, token and all.
  final Uri uri;

  /// The daemon's own label, e.g. `Kind: Flutter - Device: … - Package: …`.
  final String? name;
}

/// The [DtdInstance] in a pid file, or null when the file is not one.
///
/// [name] is the file's name, which is the pid; a file not named after a
/// number is somebody else's and is refused rather than parsed.
DtdInstance? parseDtdPidFile(String name, String contents) {
  final named = int.tryParse(name);
  if (named == null) return null;

  final Object? decoded;
  try {
    decoded = jsonDecode(contents);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;

  final raw = decoded['wsUri'];
  if (raw is! String) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;

  final epoch = decoded['epoch'];
  return DtdInstance(
    pid: decoded['pid'] is int ? decoded['pid']! as int : named,
    wsUri: uri,
    workspaceRoot: decoded['workspaceRoot'] is String
        ? decoded['workspaceRoot']! as String
        : '',
    startedAt: DateTime.fromMillisecondsSinceEpoch(
      epoch is int ? epoch : 0,
      isUtc: true,
    ),
    dartVersion: decoded['dartVersion'] is String
        ? decoded['dartVersion']! as String
        : null,
  );
}

/// The apps in a `ConnectedApp.getVmServices` result.
///
/// Liberal in what it accepts: a daemon of another version, or a reply of
/// another shape, yields an empty list rather than an exception — this runs
/// against whatever Dart SDK the user happens to have.
List<DtdApp> vmServicesInDtdReply(String resultJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(resultJson);
  } on FormatException {
    return const <DtdApp>[];
  }
  if (decoded is! Map<String, Object?>) return const <DtdApp>[];
  final services = decoded['vmServices'];
  if (services is! List) return const <DtdApp>[];

  final found = <DtdApp>[];
  for (final entry in services) {
    if (entry is! Map) continue;
    final raw = entry['uri'];
    if (raw is! String) continue;
    // Normalised here so a daemon that hands back an http form and one that
    // hands back a ws form are the same row.
    final uri = normaliseVmServiceUri(raw);
    if (uri == null || !uri.hasPort) continue;
    final name = entry['name'];
    found.add(DtdApp(uri: uri, name: name is String ? name : null));
  }
  return found;
}

/// Where daemons write themselves down, or null when this environment does not
/// say.
///
/// `dart tooling-daemon --list` reads the same directory, through
/// `package:dart_data_home`. Only the Windows answer is measured here; the
/// other two follow the package's rule and are unverified on this machine, so
/// a missing variable yields null rather than a guessed path (§19).
String? dtdPidFileDirectory(
  Map<String, String> environment, {
  required bool isWindows,
}) {
  final override = environment['DART_DATA_HOME'];
  if (override != null && override.isNotEmpty) {
    return _join(override, 'dtd', isWindows: isWindows);
  }
  if (isWindows) {
    final local = environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    return _join(_join(local, 'Dart', isWindows: true), 'dtd', isWindows: true);
  }
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return null;
  final state = environment['XDG_STATE_HOME'];
  final base = state != null && state.isNotEmpty
      ? state
      : _join(_join(home, '.local', isWindows: false), 'state', isWindows: false);
  return _join(_join(base, 'Dart', isWindows: false), 'dtd', isWindows: false);
}

String _join(String base, String name, {required bool isWindows}) {
  final separator = isWindows ? r'\' : '/';
  final trimmed = base.replaceAll(RegExp(r'[\\/]+$'), '');
  return '$trimmed$separator$name';
}
