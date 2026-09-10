/// One debuggable target from Chrome's `/json/list`. Only pages are drivable;
/// workers, extension backgrounds and the browser target are filtered out by
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

  /// Whether this is an ordinary page we can drive. `devtools://` is the
  /// DevTools UI itself and `chrome://` refuses most commands.
  bool get isDrivablePage =>
      type == 'page' &&
      webSocketDebuggerUrl != null &&
      !url.startsWith('devtools://');

  @override
  String toString() => 'BrowserTarget($type $id ${url.isEmpty ? '-' : url})';
}
