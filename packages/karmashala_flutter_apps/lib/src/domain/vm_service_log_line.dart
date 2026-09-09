/// The Dart VM's own announcement of its service address, as it reaches a
/// device log.
///
/// The address carries an auth token minted per run that nothing outside the
/// app can recompute, so "connect to any running app" is bounded by where the
/// token can be *read*. On Android it is read here: the VM writes the line to
/// stdout and Android routes it to `logcat` under the `flutter` tag.
library;

/// The same match `flutter attach` makes — `kVMServiceMessageRegExp` in
/// `flutter_tools/lib/src/globals.dart`. The `//` alternative is not
/// decoration: some builds omit the scheme.
final RegExp _announcement = RegExp(
  r'The Dart VM service is listening on ((?:http|//)[a-zA-Z0-9:/=_\-.\[\]]+)',
);

/// The **device-side** address a Dart VM announced in [line], or null.
///
/// Matched anywhere in the line, so a logcat prefix needs no stripping. The
/// port is a port on the phone: unreachable from here until an `adb forward`
/// exists, which is [vmServiceUriOnHost]'s half.
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

/// The same VM service reached through an `adb forward` on [hostPort].
///
/// Only the authority moves; the token is carried over because it is the half
/// that cannot be re-derived. `buildVMServiceUri` in flutter_tools does the
/// same.
Uri vmServiceUriOnHost(Uri deviceUri, int hostPort) => Uri(
  scheme: 'http',
  host: '127.0.0.1',
  port: hostPort,
  path: deviceUri.path,
);
