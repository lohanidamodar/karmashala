import 'vm_service_uri.dart';

/// How many rows after the announcement a wrapped address may still be on.
const int kVmServiceAnnouncementSpan = 2;

/// The VM service address a `flutter run` has announced in its pane, or null.
///
/// Rows rather than a line: `printStatus` wraps at the terminal's width, so in
/// a narrow pane the URL is already on a row of its own. The DevTools line
/// carries the same address as a *query parameter*, which is why a candidate
/// with a query is refused outright.
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
    // An address with no port is not one `flutter run` printed.
    if (uri != null && uri.hasPort) return uri;
  }
  return null;
}
