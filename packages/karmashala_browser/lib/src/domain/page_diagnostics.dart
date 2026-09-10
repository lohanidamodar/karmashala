/// What the page complained about while we were driving it. Two kinds, kept
/// apart because a console message is the page's own code saying something went
/// wrong and a network failure is a request that did not come back.
class ConsoleMessage {
  const ConsoleMessage({
    required this.level,
    required this.text,
    required this.at,
    this.source,
  });

  /// `error` or `warning`. Everything quieter is dropped at capture time — a
  /// page's `console.log` chatter is not evidence.
  final String level;

  final String text;

  /// Where it came from: a script URL with a line number, when the page said.
  final String? source;

  final DateTime at;

  bool get isError => level == 'error';

  /// The identity used to drop duplicates: some Chrome versions report one
  /// `console.error` twice, and a run listing it twice reads as two bugs.
  String get fingerprint => '$level|$text|${source ?? ''}';

  String toLine() => '[$level] $text${source == null ? '' : '  ($source)'}';
}

/// A request that failed, or came back with a status the page cannot use.
class NetworkFailure {
  const NetworkFailure({
    required this.url,
    required this.at,
    this.method,
    this.status,
    this.errorText,
  });

  final String url;
  final String? method;

  /// The HTTP status, for a response that arrived and was >= 400.
  final int? status;

  /// Chrome's own reason, for a request that never arrived at all
  /// (`net::ERR_CONNECTION_REFUSED`, `net::ERR_NAME_NOT_RESOLVED`…).
  final String? errorText;

  final DateTime at;

  String get fingerprint =>
      '${method ?? ''}|$url|${status ?? ''}|'
      '${errorText ?? ''}';

  String toLine() =>
      [?method, if (status != null) '$status' else ?errorText, url].join(' ');
}
