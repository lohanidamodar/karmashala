/// Turns whatever spelling of a Dart VM service address we were handed into the
/// `ws://…/ws` one a client can actually connect to.
///
/// Three spellings reach this app for the same running program, and they are
/// not interchangeable:
///
/// * `ws://127.0.0.1:53119/bt32nsO63q8=/ws` — what
///   `flutter run --vmservice-out-file=<path>` writes into that file, verbatim
///   (`ResidentRunner.writeVmServiceFile` writes `vmService.wsAddress`).
/// * `http://127.0.0.1:53119/bt32nsO63q8=/` — what `flutter run` *prints*, and
///   therefore what a user copies out of a terminal.
/// * `ws://127.0.0.1:53119/bt32nsO63q8=/` — the same, half-converted, which is
///   what a person who knows it is a WebSocket usually types.
///
/// The auth token is a path segment containing `=`, so it is rebuilt rather
/// than string-concatenated: `Uri` keeps `=` in a path segment (RFC 3986
/// sub-delims) and `vm_service_uri_test` pins that it comes back unmangled.
///
/// Returns `null` for anything that is not one of the three. A refusal here is
/// what lets the caller say "that is not a VM service address" instead of
/// opening a socket to whatever the user pasted.
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

/// The address as `flutter run` prints it, for showing back to a human.
///
/// Only the scheme and the trailing `/ws` differ, and the printed form is the
/// one that appears in a terminal — so a user comparing the two can see they
/// are the same program.
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
