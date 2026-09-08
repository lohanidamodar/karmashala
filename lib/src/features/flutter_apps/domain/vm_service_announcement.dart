import 'vm_service_uri.dart';

/// How many rows after the announcement a wrapped address may still be on.
///
/// One is enough for every width down to about thirty columns; two is the
/// slack for a very narrow pane, where the sentence itself wraps as well.
const int kVmServiceAnnouncementSpan = 2;

/// The VM service address a `flutter run` has announced in its pane, or null
/// when it has not announced one yet.
///
/// ## Why this reads *rows* and not a line
///
/// `flutter run` prints, from `ResidentRunner.printDebuggerList`:
///
/// ```txt
/// A Dart VM Service on sdk gphone64 x86 64 is available at: http://127.0.0.1:53119/AbCdEf=/
/// ```
///
/// and the source above it says *"Caution: This log line is parsed by device
/// lab tests"*, so the wording is a contract rather than an accident. What is
/// **not** stable is that it arrives as one line. Two things re-flow it before
/// anything here can see it:
///
/// * `printStatus` wraps its own output whenever stdout is a terminal —
///   `OutputPreferences.wrapText` defaults to `stdio.hasTerminal` and
///   `wrapColumn` to the terminal's own width — and `_wrapTextAsLines` backs up
///   to the last whitespace, which is the space before the address. So in any
///   pane narrower than the sentence, the URL is already on a line of its own.
/// * The pane is a grid. Whatever the process emitted, what can be read back
///   is rows at the pane's width.
///
/// So the announcement is matched, and the address is taken from that row or
/// the [kVmServiceAnnouncementSpan] rows after it.
///
/// ## Why the DevTools line cannot be mistaken for it
///
/// `flutter run` also prints *"The Flutter DevTools debugger and profiler on
/// … is available at: http://127.0.0.1:9101?uri=http://127.0.0.1:53119/AbCdEf=/"*
/// — which **contains the real address as a query parameter**. A scan for
/// anything URL-shaped would take the DevTools port and connect to a web
/// server. Two guards: the announcement must say `Dart VM Service`, and a
/// candidate carrying a query is refused outright.
Uri? vmServiceUriInPaneRows(List<String> rows) {
  for (var index = 0; index < rows.length; index++) {
    if (!_isAnnouncement(rows[index])) continue;
    final last = index + kVmServiceAnnouncementSpan;
    for (var scan = index; scan <= last && scan < rows.length; scan++) {
      final uri = _addressIn(rows[scan]);
      if (uri != null) return uri;
    }
  }
  return null;
}

bool _isAnnouncement(String row) =>
    row.contains('Dart VM Service') && !row.contains('DevTools');

final RegExp _candidate = RegExp(r'(?:https?|wss?)://[^\s"]+');

Uri? _addressIn(String row) {
  for (final match in _candidate.allMatches(row)) {
    final token = match.group(0)!;
    // A query means DevTools carrying the address inside it, not the address.
    if (token.contains('?')) continue;
    final uri = normaliseVmServiceUri(token);
    // An address with no port is not one `flutter run` printed; refusing here
    // keeps a stray link in a log line out of the connection path.
    if (uri != null && uri.hasPort) return uri;
  }
  return null;
}
