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

/// Every directory a daemon may have written itself down in, per the SDK's
/// `getDartDataHome('dtd')` (docs/SETTLED.md); empty when the environment names
/// none. An override adds a candidate: the daemon resolved it in *its* env.
List<String> dtdPidFileDirectories(
  Map<String, String> environment, {
  required String operatingSystem,
}) {
  final isWindows = operatingSystem == 'windows';
  String join(String base, List<String> names) {
    final separator = isWindows ? r'\' : '/';
    var path = base.replaceAll(RegExp(r'[\\/]+$'), '');
    for (final name in names) {
      path = '$path$separator$name';
    }
    return path;
  }

  String? named(String key) {
    final value = environment[key];
    return value == null || value.isEmpty ? null : value;
  }

  final found = <String>[];
  final override = named('DART_DATA_HOME');
  if (override != null) found.add(join(override, const ['dtd']));

  switch (operatingSystem) {
    case 'windows':
      final local = named('LOCALAPPDATA');
      if (local != null) found.add(join(local, const ['Dart', 'dtd']));
    case 'macos':
      final home = named('HOME');
      if (home != null) {
        found.add(
          join(home, const ['Library', 'Application Support', 'Dart', 'dtd']),
        );
      }
    case 'linux':
      final state = named('XDG_STATE_HOME');
      if (state != null) found.add(join(state, const ['Dart', 'dtd']));
      final home = named('HOME');
      if (home != null) {
        found.add(join(home, const ['.local', 'state', 'Dart', 'dtd']));
      }
  }
  return found.toSet().toList();
}
