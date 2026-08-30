/// One debuggable target reported by Chrome's `/json/list` endpoint.
///
/// Only pages are drivable; service workers, extension backgrounds and the
/// browser target itself also appear in that list and are filtered out by
/// [isDrivablePage].
class BrowserTarget {
  const BrowserTarget({
    required this.id,
    required this.type,
    required this.title,
    required this.url,
    required this.webSocketDebuggerUrl,
  });

  final String id;
  final String type;
  final String title;
  final String url;

  /// The per-target WebSocket endpoint. Null for targets Chrome will not let
  /// us attach to (already-attached targets report no URL).
  final String? webSocketDebuggerUrl;

  /// Whether this target is an ordinary page we can attach to and drive.
  ///
  /// `devtools://` pages are the DevTools UI itself and `chrome://` pages
  /// refuse most commands, so both are excluded.
  bool get isDrivablePage =>
      type == 'page' &&
      webSocketDebuggerUrl != null &&
      !url.startsWith('devtools://');

  @override
  String toString() => 'BrowserTarget($type $id ${url.isEmpty ? '-' : url})';
}
