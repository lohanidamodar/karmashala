import 'dart:convert';

/// The string at [path] in the JSON [body], or `''` for anything else — a
/// missing key, a non-string value, or a body that is not JSON at all.
///
/// One copy, because two readers of the same declared path is how adoption and
/// the sidebar would come to disagree about where an agent is.
String hookStringAt(List<String> path, String body) {
  Object? value;
  try {
    value = jsonDecode(body);
  } on FormatException {
    return '';
  }
  for (final segment in path) {
    if (value is Map) {
      value = value[segment];
    } else if (value is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= value.length) return '';
      value = value[index];
    } else {
      return '';
    }
  }
  if (value is String) return value;
  // Antigravity declares `workspacePaths`, a list; the first is the one it is
  // working in.
  if (value is List && value.isNotEmpty && value.first is String) {
    return value.first as String;
  }
  return '';
}
