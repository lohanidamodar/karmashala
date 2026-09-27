/// A session on an SSH box, named at the server that reaches it (slice 5d):
/// `ssh:<hostId>/<sessionId>`. A client attaches to that id at its own
/// server exactly as to a local one; the server relays the box host's frames
/// by ref. The box's own id (`sessionId`) is what its host holds — so a
/// session survives the server restarting, since the box keeps it.
String boxSessionRef(String hostId, String sessionId) =>
    '$kBoxSessionPrefix$hostId/$sessionId';

const String kBoxSessionPrefix = 'ssh:';

/// The box and its session [ref] names, or null for a session of the
/// server's own (every id not starting `ssh:`).
({String hostId, String sessionId})? parseBoxSessionRef(String ref) {
  if (!ref.startsWith(kBoxSessionPrefix)) return null;
  final rest = ref.substring(kBoxSessionPrefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  return (hostId: rest.substring(0, slash), sessionId: rest.substring(slash + 1));
}
