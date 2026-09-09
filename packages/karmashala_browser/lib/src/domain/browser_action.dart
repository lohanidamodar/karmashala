import 'dart:typed_data';

/// Something the browser feature did, reported to whoever is recording.
///
/// The seam exists so a verification run can watch the *existing*
/// [BrowserService] rather than a second, recording copy of it: the pane, the
/// MCP tools and a test harness all drive the same object, so all three are
/// recorded by construction. The browser feature knows nothing about runs — it
/// reports, and something else decides whether anyone is listening.
class BrowserAction {
  const BrowserAction({
    required this.verb,
    required this.summary,
    this.detail,
    this.ok = true,
    this.png,
    this.text,
    this.pageUrl,
  });

  /// What was done: `navigate`, `click`, `type`, `screenshot`, `capture`…
  /// Chosen from a small vocabulary so a recorder can classify without parsing
  /// prose.
  final String verb;

  /// One line: the action and its target.
  final String summary;

  /// Anything longer — the expression evaluated, the error that came back.
  final String? detail;

  final bool ok;

  /// An image this action produced, if any. Handed over rather than written
  /// here: where evidence is stored is not the browser's business.
  final Uint8List? png;

  /// A text payload worth keeping as a file — an element bundle, mostly.
  final String? text;

  /// Where the page was when this happened, when the caller already knew.
  final String? pageUrl;

  BrowserAction failed(Object error) => BrowserAction(
    verb: verb,
    summary: summary,
    detail: '$error',
    ok: false,
    pageUrl: pageUrl,
  );
}

/// Where [BrowserAction]s go. Null means nobody is recording.
typedef BrowserActionSink = void Function(BrowserAction action);
