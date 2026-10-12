import 'dart:convert';

import 'log_redactor.dart';

/// What everything an agent says passes through before Karmashala logs,
/// stores or sends it: agents echo their MCP configs, environments and login
/// prompts, and none of that is ours to keep.
class AgentRedactor {
  AgentRedactor._();

  static final LogRedactor _text = LogRedactor();

  /// Longest agent text kept in one place; the rest is counted, not kept.
  static const int maxText = 4000;

  static const String masked = '[redacted]';

  static final RegExp _secretKey = RegExp(
    r'(token(?!s(?:$|[_a-z])|_?count|_?limit|izer|_?usage|_?type)|secret|password|passwd|passphrase|api[_-]?key|apikey'
    r'|auth[_-]?key|access[_-]?key|private[_-]?key|authorization|cookie'
    r'|credential)',
    caseSensitive: false,
  );

  /// Whether a field or variable named [key] holds a secret by its name.
  static bool isSecretKey(String key) =>
      _secretKey.hasMatch(key) && !_addressKey.hasMatch(key);

  // A login link is what the user needs from a login, so it is never masked
  // by its name.
  static final RegExp _addressKey = RegExp(
    r'(url|uri|link)$',
    caseSensitive: false,
  );

  /// [input] with every known token shape and named secret masked, and cut
  /// to [limit] characters. The masking is idempotent.
  static String text(String input, {int limit = maxText}) {
    final out = _text.apply(input.replaceAllMapped(_envBlock, _maskEnvBlock));
    if (out.length <= limit) return out;
    return '${out.substring(0, limit)}… [${out.length - limit} more chars]';
  }

  // An `env` or `headers` object or list printed as JSON, whose values are
  // secret whatever their names.
  static final RegExp _envBlock = RegExp(
    r'"(?:env|headers)"\s*:\s*(?:\{[^{}]*\}|\[(?:[^\[\]{}]|\{[^{}]*\})*\])',
  );
  static final RegExp _stringField = RegExp(
    r'("[^"\\]*"\s*:\s*)"(?:[^"\\]|\\.)*"',
  );

  static String _maskEnvBlock(Match block) => block[0]!.replaceAllMapped(
    _stringField,
    (field) =>
        field[1]!.startsWith('"name"') ? field[0]! : '${field[1]}"$masked"',
  );

  /// [value] with `env` and `headers` values dropped, every field whose key
  /// names a secret masked, and every string passed through [text].
  static Object? json(Object? value, {int limit = maxText}) =>
      _json(value, limit, null);

  /// The JSON text [encoded] after [json]; text that is not JSON goes
  /// through [text].
  static String jsonText(String encoded, {int limit = maxText}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      return text(encoded, limit: limit);
    }
    return jsonEncode(json(decoded, limit: limit));
  }

  /// How a message Karmashala does not handle is mentioned in a log: its
  /// method and size, never its payload.
  static String unhandled(String method, Object? params) {
    var bytes = 0;
    try {
      bytes = utf8.encode(jsonEncode(params)).length;
    } catch (_) {}
    return '${text(method, limit: 120)} ($bytes bytes)';
  }

  static Object? _json(Object? value, int limit, String? key) {
    if (value is String) {
      if (key != null && isSecretKey(key) && value.isNotEmpty) return masked;
      return text(value, limit: limit);
    }
    if (value is List) {
      final pairs = key == 'env' || key == 'headers';
      return [
        for (final item in value)
          pairs && item is Map ? _pair(item, limit) : _json(item, limit, key),
      ];
    }
    if (value is Map) {
      if (key == 'env' || key == 'headers') {
        return {for (final k in value.keys) '$k': masked};
      }
      if (value.containsKey('name') && value.containsKey('value')) {
        final name = value['name'];
        if (name is String && isSecretKey(name)) return _pair(value, limit);
      }
      return {
        for (final entry in value.entries)
          '${entry.key}': _json(entry.value, limit, '${entry.key}'),
      };
    }
    if (key != null && isSecretKey(key) && value is num) return masked;
    return value;
  }

  /// One `{name, value}` of an ACP `env` or `headers` list: the name stays,
  /// so the config is still readable, and the value never does.
  static Map<String, Object?> _pair(Map<Object?, Object?> pair, int limit) => {
    for (final entry in pair.entries)
      '${entry.key}': entry.key == 'value'
          ? masked
          : _json(entry.value, limit, '${entry.key}'),
  };
}
