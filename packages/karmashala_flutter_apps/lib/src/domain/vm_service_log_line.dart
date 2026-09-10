/// The Dart VM's own announcement of its service address, as it reaches a
/// device log. The per-run auth token cannot be recomputed, so this — logcat
/// under the `flutter` tag — is where Android's is read.
library;

/// The same match `flutter attach` makes. The `//` alternative is not
/// decoration: some builds omit the scheme.
final RegExp _announcement = RegExp(
  r'The Dart VM service is listening on ((?:http|//)[a-zA-Z0-9:/=_\-.\[\]]+)',
);

/// The **device-side** address a Dart VM announced in [line], or null. The
/// port is the phone's, unreachable here until an `adb forward` exists.
Uri? vmServiceUriInDeviceLogLine(String line) {
  final match = _announcement.firstMatch(line);
  if (match == null) return null;

  final Uri parsed;
  try {
    parsed = Uri.parse(match.group(1)!);
  } on FormatException {
    return null;
  }
  if (parsed.host.isEmpty || !parsed.hasPort) return null;

  // The VM answers 403 without the trailing slash, so it is put back.
  final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
  return Uri(
    scheme: parsed.scheme.isEmpty ? 'http' : parsed.scheme,
    host: parsed.host,
    port: parsed.port,
    path: path,
  );
}

/// The same VM service reached through an `adb forward` on [hostPort]: only
/// the authority moves, because the token cannot be re-derived.
Uri vmServiceUriOnHost(Uri deviceUri, int hostPort) => Uri(
  scheme: 'http',
  host: '127.0.0.1',
  port: hostPort,
  path: deviceUri.path,
);
