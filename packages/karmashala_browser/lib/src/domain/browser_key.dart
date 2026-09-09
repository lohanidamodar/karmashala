/// A named key that can be pressed in the page.
///
/// `Input.dispatchKeyEvent` needs four agreeing fields — `key`, `code`,
/// `windowsVirtualKeyCode` and (for printable keys) `text`. Getting one wrong
/// produces an event the page's own handlers quietly ignore, so the table is
/// kept in one place and unit-tested rather than spelled out at each call.
class BrowserKey {
  const BrowserKey({
    required this.name,
    required this.key,
    required this.code,
    required this.virtualKeyCode,
    this.text,
  });

  /// The name a caller uses: `enter`, `tab`, `arrowDown`…
  final String name;

  /// DOM `KeyboardEvent.key`.
  final String key;

  /// DOM `KeyboardEvent.code`.
  final String code;
  final int virtualKeyCode;

  /// The character the key inserts, for keys that insert one.
  final String? text;

  /// Params for `Input.dispatchKeyEvent` of the given [type].
  Map<String, Object?> params(String type) => {
    'type': type,
    'key': key,
    'code': code,
    'windowsVirtualKeyCode': virtualKeyCode,
    'nativeVirtualKeyCode': virtualKeyCode,
    if (text != null && type != 'keyUp') ...{
      'text': text,
      'unmodifiedText': text,
    },
  };
}

/// Every key [parseBrowserKey] accepts.
const List<BrowserKey> kBrowserKeys = [
  BrowserKey(
    name: 'enter',
    key: 'Enter',
    code: 'Enter',
    virtualKeyCode: 13,
    text: '\r',
  ),
  BrowserKey(
    name: 'tab',
    key: 'Tab',
    code: 'Tab',
    virtualKeyCode: 9,
    text: '\t',
  ),
  BrowserKey(name: 'escape', key: 'Escape', code: 'Escape', virtualKeyCode: 27),
  BrowserKey(
    name: 'backspace',
    key: 'Backspace',
    code: 'Backspace',
    virtualKeyCode: 8,
  ),
  BrowserKey(name: 'delete', key: 'Delete', code: 'Delete', virtualKeyCode: 46),
  BrowserKey(
    name: 'space',
    key: ' ',
    code: 'Space',
    virtualKeyCode: 32,
    text: ' ',
  ),
  BrowserKey(
    name: 'arrowUp',
    key: 'ArrowUp',
    code: 'ArrowUp',
    virtualKeyCode: 38,
  ),
  BrowserKey(
    name: 'arrowDown',
    key: 'ArrowDown',
    code: 'ArrowDown',
    virtualKeyCode: 40,
  ),
  BrowserKey(
    name: 'arrowLeft',
    key: 'ArrowLeft',
    code: 'ArrowLeft',
    virtualKeyCode: 37,
  ),
  BrowserKey(
    name: 'arrowRight',
    key: 'ArrowRight',
    code: 'ArrowRight',
    virtualKeyCode: 39,
  ),
  BrowserKey(name: 'home', key: 'Home', code: 'Home', virtualKeyCode: 36),
  BrowserKey(name: 'end', key: 'End', code: 'End', virtualKeyCode: 35),
  BrowserKey(name: 'pageUp', key: 'PageUp', code: 'PageUp', virtualKeyCode: 33),
  BrowserKey(
    name: 'pageDown',
    key: 'PageDown',
    code: 'PageDown',
    virtualKeyCode: 34,
  ),
];

/// Resolves a key name, case- and separator-insensitively (`arrowdown`,
/// `ArrowDown`, `arrow_down` and `arrow-down` are the same key).
BrowserKey? parseBrowserKey(String? name) {
  if (name == null) return null;
  final needle = name.trim().toLowerCase().replaceAll(RegExp('[-_ ]'), '');
  for (final key in kBrowserKeys) {
    if (key.name.toLowerCase() == needle) return key;
    if (key.key.toLowerCase() == needle) return key;
  }
  return null;
}

/// The key names, for an error message that says what is allowed.
String get browserKeyNames => kBrowserKeys.map((k) => k.name).join(', ');
