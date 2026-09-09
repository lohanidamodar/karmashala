import 'dart:convert';

import '../domain/browser_failure.dart';
import '../domain/browser_target.dart';

/// Reads the value out of a `Runtime.evaluate` / `Runtime.callFunctionOn`
/// reply, raising [BrowserException] when the page threw.
///
/// Assumes `returnByValue: true`; without it CDP returns an object handle and
/// there is no `value` to read, which this reports rather than silently
/// yielding null.
Object? unwrapEvaluateResult(Map<String, Object?> reply) {
  final details = reply['exceptionDetails'];
  if (details is Map<String, Object?>) {
    throw BrowserException(
      BrowserFailure.evaluationFailed,
      describeBrowserFailure(
        BrowserFailure.evaluationFailed,
        detail: describeEvaluationException(details),
      ),
    );
  }
  final remote = reply['result'];
  if (remote is! Map<String, Object?>) {
    throw BrowserException(
      BrowserFailure.malformedResponse,
      describeBrowserFailure(
        BrowserFailure.malformedResponse,
        detail: 'Runtime.evaluate returned no result object',
      ),
    );
  }
  final type = remote['type'];
  if (type == 'undefined') return null;
  if (remote.containsKey('value')) return remote['value'];
  if (remote.containsKey('unserializableValue')) {
    return remote['unserializableValue'];
  }
  // An object handle came back instead of a value: the caller forgot
  // returnByValue, or the value is not JSON-serialisable.
  return null;
}

/// The most useful single line out of a CDP `ExceptionDetails`.
String describeEvaluationException(Map<String, Object?> details) {
  final exception = details['exception'];
  if (exception is Map<String, Object?>) {
    final description = exception['description'];
    if (description is String && description.isNotEmpty) {
      return description.split('\n').first;
    }
    final value = exception['value'];
    if (value != null) return value.toString();
  }
  final text = details['text'];
  return text is String && text.isNotEmpty ? text : 'unknown JavaScript error';
}

/// Flattens `CSS.getComputedStyleForNode`'s `[{name, value}, ...]` into a map.
Map<String, String> parseComputedStyle(Map<String, Object?> reply) {
  final entries = reply['computedStyle'];
  if (entries is! List) return const {};
  final styles = <String, String>{};
  for (final entry in entries) {
    if (entry is! Map) continue;
    final name = entry['name'];
    final value = entry['value'];
    if (name is String && value is String) styles[name] = value;
  }
  return styles;
}

/// Parses the JSON body of Chrome's `/json/list` endpoint.
List<BrowserTarget> parseTargetList(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw BrowserException(
      BrowserFailure.malformedResponse,
      describeBrowserFailure(
        BrowserFailure.malformedResponse,
        detail: '/json/list was not JSON: ${e.message}',
      ),
    );
  }
  if (decoded is! List) {
    throw BrowserException(
      BrowserFailure.malformedResponse,
      describeBrowserFailure(
        BrowserFailure.malformedResponse,
        detail: '/json/list was not a JSON array',
      ),
    );
  }
  return [
    for (final entry in decoded)
      if (entry is Map<String, Object?>) parseTarget(entry),
  ];
}

/// Parses one entry of `/json/list` (or the reply of `PUT /json/new`).
BrowserTarget parseTarget(Map<String, Object?> json) => BrowserTarget(
  id: json['id']?.toString() ?? '',
  type: json['type']?.toString() ?? '',
  title: json['title']?.toString() ?? '',
  url: json['url']?.toString() ?? '',
  webSocketDebuggerUrl: json['webSocketDebuggerUrl'] as String?,
);

/// Whether a `/json/version` body really is a Chrome DevTools endpoint.
///
/// This is how "port occupied by an unrelated server" is told apart from
/// "Chrome is listening here": any HTTP server can answer on the port, but
/// only DevTools reports a browser and a browser-level WebSocket URL.
bool isDevToolsVersionBody(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) return false;
    return decoded.containsKey('webSocketDebuggerUrl') ||
        decoded['Browser'] is String;
  } on FormatException {
    return false;
  }
}
