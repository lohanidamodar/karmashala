/// OSC 7 — the shell reporting the directory it is in *now*.
///
/// Pure Dart on purpose — no Flutter, no xterm, no `Platform` — for the same
/// reason `command_blocks.dart` is: the protocol is the whole of the risk here,
/// and it should be testable without a terminal, a process or a widget tree.
/// The caller supplies this machine's name; nothing here goes looking for it.
library;

/// A drive-letter path as it arrives inside a file URI: `/C:/src/app`.
///
/// The leading slash is URI syntax, not part of the path.
final RegExp _driveLetter = RegExp(r'^/[A-Za-z]:');

/// A `%` that is not the start of a valid escape.
///
/// `Uri.parse` quietly rewrites `%zz` to `%25zz` — it repairs the input rather
/// than rejecting it, which would turn a garbled sequence into a plausible
/// directory. Checked against the raw payload so that repair never happens.
final RegExp _malformedEscape = RegExp('%(?![0-9A-Fa-f]{2})');

/// The directory carried by an `OSC 7 ; file://<host>/<path>`, or `null` when
/// the sequence is not one we can read.
///
/// [code] is the OSC number and [args] everything after it, exactly as xterm's
/// `onPrivateOSC` dispatches them — so `OSC 7 ; file:///C:/src ST` arrives as
/// `('7', ['file:///C:/src'])`.
///
/// `null` always means *no answer*, never *the pane has no directory*: a caller
/// keeps what it already had. Every rejection is a case where answering would
/// mean guessing:
///
/// * **not an OSC 7**, or an empty payload — there is nothing to read;
/// * **a scheme other than `file:`** — `http://…` is a page, not a directory;
/// * **a host that is not this machine** — an ssh session inside the pane
///   reports its *own* host, and that path does not exist here. An empty host
///   and `localhost` are always this machine. (A WSL pane passes because
///   `wsl.exe` gives the distribution the Windows machine's name by default.)
/// * **a malformed URI or percent escape** — see [_malformedEscape].
///
/// A Windows path arrives as `file:///C:/src/app`: the slash before the drive
/// letter goes, and the separators are turned into the spelling every other
/// path in the app uses.
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
