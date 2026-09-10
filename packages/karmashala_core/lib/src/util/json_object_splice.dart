/// Textually replaces the value of a **top-level** property, leaving the rest of
/// the document byte-for-byte intact — `~/.claude.json` holds keys differing
/// only by case (`g:/x`, `G:/x`) that a decode→encode round-trip would collapse.
///
/// [newValueJson] is inserted verbatim and must already be valid JSON; an
/// absent [key] is inserted first. Throws [FormatException] on anything that is
/// not a well-formed JSON object.
String replaceTopLevelJsonValue(
  String rawJson,
  String key,
  String newValueJson,
) {
  final scanner = _Scanner(rawJson);
  final objectStart = scanner.skipWsFrom(0);
  if (objectStart >= rawJson.length || rawJson[objectStart] != '{') {
    throw const FormatException('Root value is not a JSON object');
  }

  var i = objectStart + 1;
  while (true) {
    i = scanner.skipWsFrom(i);
    if (i >= rawJson.length) {
      throw const FormatException('Unterminated JSON object');
    }
    if (rawJson[i] == '}') {
      // Reached the end without finding the key — insert it first.
      return _insertFirstProperty(rawJson, objectStart, key, newValueJson);
    }
    if (rawJson[i] != '"') {
      throw FormatException('Expected property name at offset $i');
    }
    final nameEnd = scanner.endOfString(i);
    final name = _decodeJsonString(rawJson.substring(i, nameEnd));
    var afterName = scanner.skipWsFrom(nameEnd);
    if (afterName >= rawJson.length || rawJson[afterName] != ':') {
      throw FormatException(
        'Expected ":" after property name at offset $afterName',
      );
    }
    final valueStart = scanner.skipWsFrom(afterName + 1);
    final valueEnd = scanner.endOfValue(valueStart);

    if (name == key) {
      return rawJson.substring(0, valueStart) +
          newValueJson +
          rawJson.substring(valueEnd);
    }

    final afterValue = scanner.skipWsFrom(valueEnd);
    if (afterValue >= rawJson.length) {
      throw const FormatException('Unterminated JSON object');
    }
    if (rawJson[afterValue] == ',') {
      i = afterValue + 1;
      continue;
    }
    if (rawJson[afterValue] == '}') {
      return _insertFirstProperty(rawJson, objectStart, key, newValueJson);
    }
    throw FormatException('Expected "," or "}" at offset $afterValue');
  }
}

/// Removes a **top-level** property, leaving the rest byte-for-byte intact;
/// returns [rawJson] unchanged when [key] is absent. Needed because
/// [replaceTopLevelJsonValue] can only empty a block, never remove one, so a
/// key we stop using would stay in the user's file for ever.
String removeTopLevelJsonKey(String rawJson, String key) {
  final scanner = _Scanner(rawJson);
  final objectStart = scanner.skipWsFrom(0);
  if (objectStart >= rawJson.length || rawJson[objectStart] != '{') {
    throw const FormatException('Root value is not a JSON object');
  }

  var i = objectStart + 1;
  var previousPairEnd = objectStart + 1;
  while (true) {
    final pairStart = scanner.skipWsFrom(i);
    if (pairStart >= rawJson.length) {
      throw const FormatException('Unterminated JSON object');
    }
    if (rawJson[pairStart] == '}') return rawJson;
    if (rawJson[pairStart] != '"') {
      throw FormatException('Expected property name at offset $pairStart');
    }
    final nameEnd = scanner.endOfString(pairStart);
    final name = _decodeJsonString(rawJson.substring(pairStart, nameEnd));
    final afterName = scanner.skipWsFrom(nameEnd);
    if (afterName >= rawJson.length || rawJson[afterName] != ':') {
      throw FormatException('Expected ":" at offset $afterName');
    }
    final valueStart = scanner.skipWsFrom(afterName + 1);
    final valueEnd = scanner.endOfValue(valueStart);
    final afterValue = scanner.skipWsFrom(valueEnd);
    if (afterValue >= rawJson.length) {
      throw const FormatException('Unterminated JSON object');
    }

    if (name == key) {
      // Take the separating comma with the pair, whichever side it is on.
      if (rawJson[afterValue] == ',') {
        return rawJson.substring(0, pairStart) +
            rawJson.substring(scanner.skipWsFrom(afterValue + 1));
      }
      return rawJson.substring(0, previousPairEnd) +
          rawJson.substring(afterValue);
    }

    if (rawJson[afterValue] == ',') {
      previousPairEnd = valueEnd;
      i = afterValue + 1;
      continue;
    }
    if (rawJson[afterValue] == '}') return rawJson;
    throw FormatException('Expected "," or "}" at offset $afterValue');
  }
}

String _insertFirstProperty(
  String rawJson,
  int objectStart,
  String key,
  String newValueJson,
) {
  final scanner = _Scanner(rawJson);
  final afterBrace = scanner.skipWsFrom(objectStart + 1);
  final isEmpty = afterBrace < rawJson.length && rawJson[afterBrace] == '}';
  final encodedKey = _encodeJsonString(key);
  final insertion = isEmpty
      ? '$encodedKey: $newValueJson'
      : '$encodedKey: $newValueJson, ';
  return rawJson.substring(0, objectStart + 1) +
      insertion +
      rawJson.substring(objectStart + 1);
}

/// Minimal offset-based scanner over a JSON string. Only the operations needed
/// by [replaceTopLevelJsonValue] are implemented.
class _Scanner {
  _Scanner(this.s);
  final String s;

  int skipWsFrom(int i) {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else {
        break;
      }
    }
    return i;
  }

  /// [start] points at the opening quote; returns the index past the closer.
  int endOfString(int start) {
    var i = start + 1;
    while (i < s.length) {
      final c = s[i];
      if (c == r'\') {
        i += 2;
        continue;
      }
      if (c == '"') return i + 1;
      i++;
    }
    throw FormatException('Unterminated string starting at offset $start');
  }

  /// [start] points at a value's first char; returns the index past that value.
  int endOfValue(int start) {
    if (start >= s.length) {
      throw const FormatException('Expected a value but reached end of input');
    }
    final c = s[start];
    if (c == '"') return endOfString(start);
    if (c == '{' || c == '[') return _endOfContainer(start);
    // A primitive runs until a structural delimiter.
    var i = start;
    while (i < s.length) {
      final ch = s[i];
      if (ch == ',' || ch == '}' || ch == ']' || _isWs(ch)) break;
      i++;
    }
    if (i == start) throw FormatException('Invalid value at offset $start');
    return i;
  }

  int _endOfContainer(int start) {
    final open = s[start];
    final close = open == '{' ? '}' : ']';
    var depth = 0;
    var i = start;
    while (i < s.length) {
      final c = s[i];
      if (c == '"') {
        i = endOfString(i);
        continue;
      }
      if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return i + 1;
      } else if (c == '{' || c == '[') {
        i = _endOfContainer(i);
        continue;
      }
      i++;
    }
    throw FormatException('Unterminated container starting at offset $start');
  }

  bool _isWs(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

String _encodeJsonString(String value) {
  final buffer = StringBuffer('"');
  for (final rune in value.runes) {
    switch (rune) {
      case 0x22:
        buffer.write(r'\"');
      case 0x5C:
        buffer.write(r'\\');
      case 0x08:
        buffer.write(r'\b');
      case 0x0C:
        buffer.write(r'\f');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        if (rune < 0x20) {
          buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  buffer.write('"');
  return buffer.toString();
}

String _decodeJsonString(String quoted) {
  // quoted includes surrounding double quotes.
  final inner = quoted.substring(1, quoted.length - 1);
  final buffer = StringBuffer();
  var i = 0;
  while (i < inner.length) {
    final c = inner[i];
    if (c != r'\') {
      buffer.write(c);
      i++;
      continue;
    }
    final next = inner[i + 1];
    switch (next) {
      case '"':
        buffer.write('"');
      case r'\':
        buffer.write(r'\');
      case '/':
        buffer.write('/');
      case 'b':
        buffer.write('\b');
      case 'f':
        buffer.write('\f');
      case 'n':
        buffer.write('\n');
      case 'r':
        buffer.write('\r');
      case 't':
        buffer.write('\t');
      case 'u':
        final hex = inner.substring(i + 2, i + 6);
        buffer.writeCharCode(int.parse(hex, radix: 16));
        i += 4;
      default:
        buffer.write(next);
    }
    i += 2;
  }
  return buffer.toString();
}
