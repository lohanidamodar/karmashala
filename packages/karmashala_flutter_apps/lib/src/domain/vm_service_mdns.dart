/// Reading a VM service address out of what an iOS app advertises over mDNS.
/// **Unchecked against a real device** — written from `flutter attach`'s own
/// reader, never measured, and nothing calls it yet for that reason.
library;

/// The service iOS apps advertise their VM service under.
const String kDartVmServiceMdnsName = '_dartVmService._tcp.local';

/// The VM service address for a simulator app, from one mDNS answer's SRV port
/// and TXT text. No `authCode=` means no address: the VM answers 403 without it.
Uri? vmServiceUriFromMdns({
  required int port,
  required String txt,
  String host = '127.0.0.1',
}) {
  if (port <= 0) return null;
  final code = _authCodeIn(txt);
  if (code == null) return null;
  return Uri(scheme: 'http', host: host, port: port, path: code);
}

String? _authCodeIn(String txt) {
  const prefix = 'authCode=';
  for (final line in txt.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith(prefix)) continue;
    final code = trimmed.substring(prefix.length);
    if (code.isEmpty) return null;
    // The VM answers 403 without the trailing slash.
    return code.endsWith('/') ? '/$code' : '/$code/';
  }
  return null;
}
