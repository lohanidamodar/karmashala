import 'dart:convert';

import 'vm_service_uri.dart';

/// The Dart Tooling Daemon — the one reader that finds a run Karmashala did
/// not start, because it records itself in a pid file and will hand out each
/// attached app's VM service URI, token included, to anyone who asks.
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

/// The [DtdInstance] in a pid file, or null when the file is not one — [name]
/// must parse as a pid, or the file is somebody else's.
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

/// The apps in a `ConnectedApp.getVmServices` result. A daemon of another
/// version yields an empty list rather than an exception.
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
    // So an http form and a ws form of the same daemon are one row.
    final uri = normaliseVmServiceUri(raw);
    if (uri == null || !uri.hasPort) continue;
    final name = entry['name'];
    found.add(DtdApp(uri: uri, name: name is String ? name : null));
  }
  return found;
}

/// Where daemons write themselves down, or null when this environment does not
/// say. Only the Windows answer is measured; the POSIX ones follow
/// `package:dart_data_home`'s rule unverified.
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
