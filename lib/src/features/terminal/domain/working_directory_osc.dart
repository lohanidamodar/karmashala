/// OSC 7 — the shell reporting the directory it is in *now*.
///
/// Pure Dart on purpose — no Flutter, no xterm, no `Platform` — so the protocol
/// is testable without a terminal, a process or a widget tree. The caller
/// supplies this machine's name; nothing here goes looking for it.
library;

/// A drive-letter path as it arrives inside a file URI: `/C:/src/app`. The
/// leading slash is URI syntax, not part of the path.
final RegExp _driveLetter = RegExp(r'^/[A-Za-z]:');

/// A `%` that is not the start of a valid escape. `Uri.parse` quietly rewrites
/// `%zz` to `%25zz` — repairing the input rather than rejecting it, which would
/// turn a garbled sequence into a plausible directory — so this is checked
/// against the raw payload.
final RegExp _malformedEscape = RegExp('%(?![0-9A-Fa-f]{2})');

/// The directory carried by an `OSC 7 ; file://<host>/<path>`, or `null` when
/// the sequence is not one we can read — `null` always means *no answer*, never
/// *the pane has no directory*, so the caller keeps what it had.
///
/// Refused: a scheme other than `file:`, a malformed URI or percent escape, and
/// a host that is not this machine — an ssh session inside the pane reports its
/// own host, and that path does not exist here.
String? workingDirectoryFromOsc(
  String code,
  List<String> args, {
  String? hostname,
}) {
  if (code != '7' || args.isEmpty) return null;
  // xterm splits an OSC on ';' and a directory may legitimately contain one, so
  // the payload is everything after the code rather than its first argument.
  final payload = args.join(';');
  if (payload.isEmpty || _malformedEscape.hasMatch(payload)) return null;

  final uri = Uri.tryParse(payload);
  if (uri == null || uri.scheme != 'file') return null;
  if (!_isThisMachine(uri.host, hostname)) return null;

  final String path;
  try {
    // `Uri.path` is still encoded; the segments are what carry the spaces.
    path = Uri.decodeComponent(uri.path);
  } catch (_) {
    return null;
  }
  // `Uri` normalises a `file:` path to an absolute one, so there is no relative
  // case to reject; this only guards the `substring` below.
  if (path.isEmpty) return null;

  if (_driveLetter.hasMatch(path)) {
    return _withoutTrailingSeparator(
      path.substring(1).replaceAll('/', r'\'),
      r'\',
    );
  }
  return _withoutTrailingSeparator(path, '/');
}

bool _isThisMachine(String host, String? hostname) {
  if (host.isEmpty || host.toLowerCase() == 'localhost') return true;
  // Without a name to compare against, no host can be confirmed as this one.
  if (hostname == null || hostname.isEmpty) return false;
  return host.toLowerCase() == hostname.toLowerCase();
}

/// Drops a trailing separator so `/src` and `/src/` are the same directory —
/// which is what stops a shell that spells it both ways looking like a `cd`.
String _withoutTrailingSeparator(String path, String separator) {
  var end = path.length;
  while (end > 1 && path[end - 1] == separator) {
    end--;
  }
  // A drive root is `C:\`, not `C:` — which on Windows means something else
  // entirely (the current directory *on* that drive).
  if (separator == r'\' && end == 2 && path.length > 2) end = 3;
  return path.substring(0, end);
}
