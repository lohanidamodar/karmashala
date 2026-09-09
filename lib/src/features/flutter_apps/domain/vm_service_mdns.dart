/// Reading a VM service address out of what an iOS app advertises over mDNS.
///
/// **Unchecked, and it says so.** There is no Mac and no iOS Simulator on the
/// machine this was written on, so nothing here has been seen against a real
/// device: it is written from `flutter attach`'s own reader
/// (`flutter_tools/lib/src/mdns_discovery.dart`) and is a *reading of the
/// documentation*, not of a device. The three Android facts next door were
/// measured; these were not, and §19's rule is that the difference is stated
/// rather than smoothed over. Nothing calls this yet for the same reason.
library;

/// The service iOS apps advertise their VM service under. `flutter attach`
/// queries the same name.
const String kDartVmServiceMdnsName = '_dartVmService._tcp.local';

/// The VM service address for a simulator app, from one mDNS answer.
///
/// [port] is the SRV record's port and [txt] the TXT record's text, whose
/// `authCode=` line is the auth token. No token means no address here: an
/// address without one is refused by the VM with 403, and guessing an empty
/// path would produce a row that can never connect.
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
    // The VM answers 403 without the trailing slash — flutter_tools appends it
    // for the same reason.
    return code.endsWith('/') ? '/$code' : '/$code/';
  }
  return null;
}
