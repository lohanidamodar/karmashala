/// Turns any of the three spellings of a Dart VM service address into the
/// `ws://…/ws` one a client can connect to, or `null` for anything else.
///
/// The auth token is a path segment containing `=`, so the URI is rebuilt
/// rather than concatenated — `Uri` keeps `=` in a path segment unmangled.
Uri? normaliseVmServiceUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  final Uri parsed;
  try {
    parsed = Uri.parse(trimmed);
  } on FormatException {
    return null;
  }
  if (parsed.host.isEmpty) return null;

  final scheme = switch (parsed.scheme) {
    'ws' || 'http' => 'ws',
    'wss' || 'https' => 'wss',
    _ => null,
  };
  if (scheme == null) return null;

  var path = parsed.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (!path.endsWith('/ws')) path = '$path/ws';
  if (!path.startsWith('/')) path = '/$path';

  return Uri(
    scheme: scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: path,
  );
}

/// The address as `flutter run` prints it, so a user comparing the two can see
/// they are the same program.
String describeVmServiceUri(Uri wsUri) {
  var path = wsUri.path;
  if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);
  final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
  return Uri(
    scheme: scheme,
    host: wsUri.host,
    port: wsUri.hasPort ? wsUri.port : null,
    path: '$path/',
  ).toString();
}
