import '../domain/ui_node.dart';

/// Parsing for `adb shell uiautomator dump`. Real dumps are messier than XML
/// from a well-behaved serializer: the command **exits 0 while printing an
/// error**, a dump taken mid-transition can carry no nodes, OEM builds leave
/// `<`, `>` and `&` unescaped inside attribute values, and the output can be
/// truncated. So the parser never throws on structure — it returns what it
/// understood, and [uiDumpFailure] classifies the command's own output.

/// AOSP's success line. The typo is upstream's, so we match the stable part.
const String _dumpedMarker = 'dumped to';

/// Why a `uiautomator dump` invocation did not produce a usable file, or
/// `null` when it looks like it worked.
class UiDumpFailure {
  const UiDumpFailure({required this.message, required this.retryable});

  final String message;

  /// Whether trying again is likely to help. "Could not get idle state" is the
  /// classic one: the screen was animating and will settle.
  final bool retryable;

  @override
  String toString() => message;
}

/// Raised when every attempt to dump the hierarchy failed. Carries the device's
/// own explanation: "never went idle" and "no window" need different responses.
class UiDumpException implements Exception {
  const UiDumpException(
    this.message, {
    required this.serial,
    this.attempts = 1,
  });

  final String message;
  final String serial;
  final int attempts;

  @override
  String toString() =>
      'Could not read the UI hierarchy from $serial after $attempts '
      'attempt${attempts == 1 ? '' : 's'}: $message';
}

/// Classifies the output of `uiautomator dump`.
///
/// [output] should be stdout and stderr together: which stream the error lands
/// on varies by Android version.
UiDumpFailure? uiDumpFailure(String output, {required bool ok}) {
  final text = output.trim();
  final lower = text.toLowerCase();
  if (lower.contains('could not get idle state')) {
    return const UiDumpFailure(
      message:
          'The screen never went idle, so uiautomator refused to dump it. '
          'Something is animating or continuously redrawing.',
      retryable: true,
    );
  }
  if (lower.contains('null root node')) {
    return const UiDumpFailure(
      message:
          'No window to dump: uiautomator got a null root node. The screen is '
          'probably off, locked, or showing a secure surface.',
      retryable: true,
    );
  }
  if (lower.contains('error:')) {
    final line = text
        .split(RegExp(r'[\r\n]+'))
        .firstWhere(
          (l) => l.toLowerCase().contains('error:'),
          orElse: () => text,
        );
    return UiDumpFailure(message: line.trim(), retryable: false);
  }
  if (!ok) {
    return UiDumpFailure(
      message: text.isEmpty ? 'uiautomator dump failed.' : text,
      retryable: false,
    );
  }
  if (!lower.contains(_dumpedMarker)) {
    return UiDumpFailure(
      message: text.isEmpty
          ? 'uiautomator dump printed nothing; it may not be present on this '
                'device.'
          : 'Unexpected uiautomator output: $text',
      retryable: false,
    );
  }
  return null;
}

/// Parses a `uiautomator dump` document into a [UiHierarchy].
///
/// Never throws: unparseable input yields an empty hierarchy, and a truncated
/// document yields the nodes that were complete before the cut.
UiHierarchy parseUiAutomatorXml(String xml) {
  final elements = _scanElements(xml);
  if (elements.isEmpty) return UiHierarchy.empty;

  // Be happy with a bare `<node>` root too — that is what a fragment of a dump
  // looks like, and it costs one line to accept.
  final root = elements.first;
  final rotation = int.tryParse(root.attributes['rotation'] ?? '') ?? 0;
  final container = root.tag == 'node' ? null : root;
  final topLevel = [
    for (final element in elements)
      if (element.tag == 'node' && identical(element.parent, container))
        element,
  ];
  return UiHierarchy(
    roots: [for (final element in topLevel) _toNode(element)],
    rotation: rotation,
  );
}

UiNode _toNode(_Element element) {
  final attributes = element.attributes;
  bool flag(String name, {bool fallback = false}) => switch (attributes[name]) {
    'true' => true,
    'false' => false,
    _ => fallback,
  };
  String string(String name) => attributes[name] ?? '';

  return UiNode(
    index: int.tryParse(attributes['index'] ?? '') ?? 0,
    text: string('text'),
    resourceId: string('resource-id'),
    className: string('class'),
    packageName: string('package'),
    contentDescription: string('content-desc'),
    bounds: UiBounds.parse(attributes['bounds']),
    checkable: flag('checkable'),
    checked: flag('checked'),
    clickable: flag('clickable'),
    // A device that omits `enabled` is likelier to have an enabled view, and
    // defaulting to disabled would make the enabled-only filter useless.
    enabled: flag('enabled', fallback: true),
    focusable: flag('focusable'),
    focused: flag('focused'),
    scrollable: flag('scrollable'),
    longClickable: flag('long-clickable'),
    password: flag('password'),
    selected: flag('selected'),
    children: [
      for (final child in element.children)
        if (child.tag == 'node') _toNode(child),
    ],
  );
}

/// A raw element from the scanner, before it becomes a [UiNode].
class _Element {
  _Element(this.tag, this.attributes, this.parent);

  final String tag;
  final Map<String, String> attributes;
  final _Element? parent;
  final List<_Element> children = [];
}

/// Scans [xml] into a tree of [_Element], in document order (so `first` is the
/// root). Iterative on purpose: an explicit stack makes truncation free —
/// whatever is still open at end of input is simply closed.
List<_Element> _scanElements(String xml) {
  final all = <_Element>[];
  final stack = <_Element>[];
  final length = xml.length;
  var i = 0;

  while (i < length) {
    final open = xml.indexOf('<', i);
    if (open < 0) break;
    i = open + 1;
    if (i >= length) break;

    // A mismatched end tag is a broken document, not a reason to discard
    // everything before it.
    if (xml[i] == '/') {
      final end = xml.indexOf('>', i);
      if (end < 0) break;
      final name = xml.substring(i + 1, end).trim();
      i = end + 1;
      final at = stack.lastIndexWhere((element) => element.tag == name);
      if (at >= 0) {
        stack.removeRange(at, stack.length);
      } else if (stack.isNotEmpty) {
        stack.removeLast();
      }
      continue;
    }

    // Prolog, comments, CDATA and declarations carry nothing we want.
    if (xml.startsWith('<?', open)) {
      final end = xml.indexOf('?>', i);
      if (end < 0) break;
      i = end + 2;
      continue;
    }
    if (xml.startsWith('<!--', open)) {
      final end = xml.indexOf('-->', i);
      if (end < 0) break;
      i = end + 3;
      continue;
    }
    if (xml.startsWith('<!', open)) {
      final end = xml.indexOf('>', i);
      if (end < 0) break;
      i = end + 1;
      continue;
    }

    final tagStart = i;
    while (i < length && !_isNameEnd(xml.codeUnitAt(i))) {
      i++;
    }
    final tag = xml.substring(tagStart, i);
    if (tag.isEmpty) continue;

    final attributes = <String, String>{};
    var selfClosing = false;
    var complete = false;
    while (i < length) {
      while (i < length && _isWhitespace(xml.codeUnitAt(i))) {
        i++;
      }
      if (i >= length) break;
      final ch = xml[i];
      if (ch == '>') {
        i++;
        complete = true;
        break;
      }
      if (ch == '/') {
        selfClosing = true;
        i++;
        continue;
      }
      final nameStart = i;
      while (i < length && !_isNameEnd(xml.codeUnitAt(i))) {
        i++;
      }
      final name = xml.substring(nameStart, i);
      if (name.isEmpty) {
        // Nothing consumed — a stray character we do not understand. Step over
        // it so the loop always terminates.
        i++;
        continue;
      }
      while (i < length && _isWhitespace(xml.codeUnitAt(i))) {
        i++;
      }
      if (i >= length || xml[i] != '=') {
        attributes[name] = '';
        continue;
      }
      i++;
      while (i < length && _isWhitespace(xml.codeUnitAt(i))) {
        i++;
      }
      if (i >= length) break;
      final quote = xml[i];
      if (quote != '"' && quote != "'") {
        // Unquoted value: take it up to the next whitespace or '>'.
        final start = i;
        while (i < length &&
            !_isWhitespace(xml.codeUnitAt(i)) &&
            xml[i] != '>') {
          i++;
        }
        attributes[name] = decodeXmlEntities(xml.substring(start, i));
        continue;
      }
      i++;
      final valueStart = i;
      // Scan to the closing quote and nothing else. This is precisely what
      // makes an unescaped `<` or `&` inside the value harmless.
      final valueEnd = xml.indexOf(quote, i);
      if (valueEnd < 0) {
        attributes[name] = decodeXmlEntities(xml.substring(valueStart));
        i = length;
        break;
      }
      attributes[name] = decodeXmlEntities(xml.substring(valueStart, valueEnd));
      i = valueEnd + 1;
    }
    if (!complete && !selfClosing) {
      // End of input inside a start tag: keep the attributes we did read.
      selfClosing = true;
    }

    final parent = stack.isEmpty ? null : stack.last;
    final element = _Element(tag, attributes, parent);
    parent?.children.add(element);
    all.add(element);
    if (!selfClosing) stack.add(element);
  }

  return all;
}

bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

bool _isNameEnd(int c) =>
    _isWhitespace(c) ||
    c == 0x3d || // =
    c == 0x2f || // /
    c == 0x3e || // >
    c == 0x3c || // <
    c == 0x22 || // "
    c == 0x27; // '

final RegExp _entityPattern = RegExp(
  r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);',
);

/// Decodes the five predefined XML entities plus numeric character references.
/// Anything else is left exactly as it was, so text is never silently corrupted.
String decodeXmlEntities(String value) {
  if (!value.contains('&')) return value;
  return value.replaceAllMapped(_entityPattern, (match) {
    final body = match.group(1)!;
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final code = body.startsWith('#x')
        ? int.tryParse(body.substring(2), radix: 16)
        : int.tryParse(body.substring(1));
    if (code == null || code < 0 || code > 0x10ffff) return match.group(0)!;
    return String.fromCharCode(code);
  });
}
