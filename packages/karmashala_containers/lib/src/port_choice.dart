import 'container_options.dart';

/// The ports listening on a host, from `ss -Htln` or `netstat -tln` lines and
/// Docker's published ports (`127.0.0.1:41022->22/tcp`). Lines it does not
/// understand are skipped.
Set<int> parseListeningPorts(String output) {
  final ports = <int>{};
  final address = RegExp(r'[:\]](\d{1,5})(?:->|$)');
  for (final line in output.split('\n')) {
    for (final word in line.trim().split(RegExp(r'[\s,]+'))) {
      final match = address.firstMatch(word);
      if (match == null) continue;
      final port = int.parse(match.group(1)!);
      if (port > 0 && port < 65536) ports.add(port);
    }
  }
  return ports;
}

/// The first port in [range] not in [taken], or null when every one is.
/// [taken] holds the host's listeners and the ports saved for other machines:
/// two saved hosts may not share `127.0.0.1:<port>`.
int? chooseContainerPort(
  Set<int> taken, {
  ({int first, int last}) range = kContainerPortRange,
}) {
  for (var port = range.first; port <= range.last; port++) {
    if (!taken.contains(port)) return port;
  }
  return null;
}
