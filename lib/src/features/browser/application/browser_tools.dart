import 'dart:convert';
import 'dart:typed_data';

import '../data/browser_launcher.dart';
import '../data/browser_service.dart';
import '../domain/browser_failure.dart';
import '../domain/browser_key.dart';
import '../domain/browser_target.dart';
import '../domain/element_capture.dart';
import '../domain/found_element.dart';

/// A tool failure whose text is the whole message.
///
/// The bridge renders a thrown error as `Error: $e`, so anything with a Dart
/// prefix ("Bad state:", "Invalid argument(s):") wastes the first words of an
/// actionable sentence. `features/browser` already writes messages worth
/// reading — this carries them through unchanged.
class BrowserToolException implements Exception {
  const BrowserToolException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The browser tools an agent sees, mapped onto [BrowserService].
///
/// Two rules shape every result here, both learnt the expensive way elsewhere
/// in this project:
///
/// * **One text block, not a JSON map.** The bridge pretty-prints a map, and
///   one JSON object per element costs several times what one line per element
///   does. Loop 34 measured a raw device dump at ~5 900 tokens and a pruned
///   listing at ~370 for the same screen.
/// * **Images are image blocks.** Base64 inside JSON is unreadable to the
///   model and enormous on the wire.
///
/// The service is the app's single [BrowserService], so these tools and the
/// browser pane drive the same page: what an agent clicks, the developer sees.
class BrowserTools {
  const BrowserTools(this._service);

  final BrowserService _service;

  /// Whether [tool] belongs to this set.
  static bool handles(String tool) => tool.startsWith('browser_');

  Future<Object?> call(String tool, Map<String, dynamic> args) async {
    try {
      return await _call(tool, args);
    } on BrowserException catch (error) {
      throw BrowserToolException(
        error.failure == BrowserFailure.notRunning && !_service.isConnected
            ? '${error.message} Call browser_connect to attach to the '
                  'browser (or browser_navigate, which connects for you).'
            : error.message,
      );
    }
  }

  Future<Object?> _call(String tool, Map<String, dynamic> args) async {
    switch (tool) {
      case 'browser_connect':
        return _connect(args);
      case 'browser_navigate':
        return _navigate(args);
      case 'browser_evaluate':
        return _evaluate(args);
      case 'browser_find':
        return _find(args);
      case 'browser_click':
        return _click(args);
      case 'browser_type':
        return _type(args);
      case 'browser_fill':
        return _fill(args);
      case 'browser_key':
        return _key(args);
      case 'browser_screenshot':
        return _screenshot(args);
      case 'browser_capture':
        return _capture(args);
      case 'browser_pick':
        return _pick(args);
      case 'browser_tabs':
        return _tabs(args);
      default:
        throw BrowserToolException('Unknown browser tool: $tool');
    }
  }

  // ---------------------------------------------------------------------------
  // Connecting
  // ---------------------------------------------------------------------------

  Future<Object?> _connect(Map<String, dynamic> args) async {
    final session = await _service.connect(
      port: _int(args['port']) ?? BrowserLauncher.defaultPort,
      spawnIfNeeded: args['spawn'] != false,
      url: _string(args['url']),
      targetId: _string(args['targetId']),
    );
    return _text([
      session.endpoint.description,
      await _whereAmI(),
      'The browser pane in Karmashala shows the same page.',
    ]);
  }

  Future<Object?> _navigate(Map<String, dynamic> args) async {
    final url = _requiredString(args, 'url');
    if (_service.isConnected) {
      await _service.navigate(url);
      return _text(['Navigated.', await _whereAmI()]);
    }
    final session = await _service.connect(
      port: _int(args['port']) ?? BrowserLauncher.defaultPort,
      url: url,
    );
    return _text([session.endpoint.description, await _whereAmI()]);
  }

  Future<Object?> _tabs(Map<String, dynamic> args) async {
    final open = _string(args['open']);
    if (open != null) {
      final tab = await _service.openTab(open);
      return _text([
        'Opened a tab: ${tab.url}',
        'The session is still driving its current page. Call '
            'browser_tabs(select: "${tab.id}") to drive the new one.',
      ]);
    }
    final select = _string(args['select']);
    if (select != null) {
      final session = await _service.connect(
        port: _service.session?.endpoint.port ?? BrowserLauncher.defaultPort,
        targetId: select,
        spawnIfNeeded: false,
      );
      return _text([
        'Now driving ${session.page.target.url}',
        await _whereAmI(),
      ]);
    }
    final targets = await _service.listTargets();
    final current = _service.session?.page.target.id;
    final pages = targets.where((t) => t.isDrivablePage).toList();
    return _text([
      '${pages.length} drivable tab${pages.length == 1 ? '' : 's'}'
          '${targets.length == pages.length ? '' : ' (of ${targets.length} '
                    'targets; the rest are workers or extensions)'}:',
      for (final tab in pages) _tabLine(tab, tab.id == current),
      '',
      'Drive one with browser_tabs(select: "<id>").',
    ]);
  }

  String _tabLine(BrowserTarget tab, bool current) =>
      '${current ? '* ' : '  '}${tab.id}  ${tab.title.isEmpty ? '(untitled)' : tab.title}  ${tab.url}';

  // ---------------------------------------------------------------------------
  // Reading the page
  // ---------------------------------------------------------------------------

  Future<Object?> _evaluate(Map<String, dynamic> args) async {
    final value = await _service.evaluate(
      _requiredString(args, 'expression'),
      awaitPromise: args['awaitPromise'] == true,
    );
    return _text([_renderValue(value)]);
  }

  Future<Object?> _find(Map<String, dynamic> args) async {
    final selector = _string(args['selector']);
    final text = _string(args['text']);
    final found = await _service.findElements(
      selector: selector,
      text: text,
      exact: args['exact'] == true,
      visibleOnly: args['includeHidden'] != true,
      limit: _int(args['limit']) ?? 25,
    );
    if (found.elements.isEmpty) {
      return _text([
        'Nothing matches ${found.query}.'
            '${found.hidden == 0 ? '' : ' ${found.hidden} match'
                      '${found.hidden == 1 ? ' is' : 'es are'} present but hidden; '
                      'pass includeHidden to see '
                      '${found.hidden == 1 ? 'it' : 'them'}.'}',
      ]);
    }
    return _text([
      '${found.total} element${found.total == 1 ? '' : 's'} match '
          '${found.query}'
          '${found.elements.length < found.total ? ', showing '
                    '${found.elements.length}' : ''}'
          '${found.hidden == 0 ? '' : ' (${found.hidden} hidden, omitted)'}.',
      'tag  "text"  `selector`  WxH at (x, y) in page coordinates',
      '',
      found.indexedListing(max: found.elements.length),
      '',
      'Act on one with browser_click(selector: …) or by text — passing index '
          'when a query matches several.',
    ]);
  }

  Future<Object?> _screenshot(Map<String, dynamic> args) async {
    final selector = _string(args['selector']);
    final fullPage = args['fullPage'] == true;
    final png = await _service.screenshot(
      selector: selector,
      fullPage: fullPage,
    );
    return _content([
      _image(png),
      _textBlock(
        '${selector == null ? (fullPage ? 'Full page' : 'Viewport') : 'Element `$selector`'} '
        'of ${await _pageLine()} — ${_kb(png)}.',
      ),
    ]);
  }

  Future<Object?> _capture(Map<String, dynamic> args) async {
    final selector = _string(args['selector']);
    final text = _string(args['text']);
    final ElementCapture capture;
    if (selector != null && text == null) {
      capture = await _service.capture(selector);
    } else {
      final found = await _service.findElements(
        selector: selector,
        text: text,
        exact: args['exact'] == true,
        limit: (_int(args['index']) ?? 0) + 1,
      );
      final index = _int(args['index']) ?? 0;
      if (found.elements.length <= index) {
        throw BrowserToolException(
          found.elements.isEmpty
              ? 'Nothing matches ${found.query}.'
              : 'index $index is out of range: ${found.query} matches '
                    '${found.total}.',
        );
      }
      final resolved = found.elements[index].selector;
      if (resolved == null) {
        throw BrowserToolException(
          'The element matching ${found.query} has no selector that resolves '
          'back to it, so it cannot be captured by query. Use browser_pick.',
        );
      }
      capture = await _service.capture(resolved);
    }
    return _captureContent(
      capture,
      full: args['full'] == true,
      image: args['image'] != false,
    );
  }

  Future<Object?> _pick(Map<String, dynamic> args) async {
    final seconds = _int(args['timeoutSeconds']) ?? 120;
    final capture = await _service.pickElement(
      timeout: Duration(seconds: seconds),
    );
    return _captureContent(
      capture,
      full: args['full'] == true,
      image: args['image'] != false,
      lead:
          'The user pointed at this element in the browser. '
          'Its markup, styles and appearance follow.',
    );
  }

  Object _captureContent(
    ElementCapture capture, {
    required bool full,
    required bool image,
    String? lead,
  }) {
    final body = full
        ? '${capture.toPromptText()}\n\nEvery computed property '
              '(${capture.computedStyles.length}):\n\n```css\n'
              '${capture.computedStyles.entries.map((e) => '${e.key}: ${e.value};').join('\n')}\n```'
        : capture.toPromptText();
    final png = capture.screenshotPng;
    return _content([
      if (image && png != null) _image(png),
      _textBlock([if (lead != null) '$lead\n', body].join()),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Driving the page
  // ---------------------------------------------------------------------------

  Future<Object?> _click(Map<String, dynamic> args) async {
    final result = await _service.click(
      selector: _string(args['selector']),
      text: _string(args['text']),
      exact: args['exact'] == true,
      index: _int(args['index']),
      clickCount: args['doubleClick'] == true ? 2 : 1,
    );
    return _text([
      'Clicked ${result.element.toListing()}'
          '${result.candidates > 1 ? ' (match ${_int(args['index']) ?? 0} of '
                    '${result.candidates})' : ''}'
          '${result.element.disabled ? ' — NOTE: this element is disabled.' : ''}',
      'at (${result.x.round()}, ${result.y.round()}) in the viewport, on '
          '${await _pageLine()}',
      'Look again (browser_find or browser_screenshot) to see what changed.',
    ]);
  }

  Future<Object?> _type(Map<String, dynamic> args) async {
    final result = await _service.type(
      _requiredString(args, 'value'),
      selector: _string(args['selector']),
      targetText: _string(args['text']),
      exact: args['exact'] == true,
      index: _int(args['index']),
      submit: args['submit'] == true,
    );
    return _text(_typeReport(result, verb: 'Typed'));
  }

  Future<Object?> _fill(Map<String, dynamic> args) async {
    final result = await _service.fill(
      selector: _string(args['selector']),
      text: _string(args['text']),
      exact: args['exact'] == true,
      index: _int(args['index']),
      value: _requiredString(args, 'value'),
      submit: args['submit'] == true,
    );
    return _text(_typeReport(result, verb: 'Filled'));
  }

  List<String> _typeReport(TypeResult result, {required String verb}) => [
    '$verb "${result.text}"'
        '${result.element == null ? ' into whatever had focus' : ' into ${result.element!.toListing()}'}'
        '${result.submitted ? ', then pressed Enter' : ''}.',
    if (result.value != null && !result.matches)
      'The field now holds "${result.value}", which is NOT what was sent — the '
          'page transformed or rejected it (a maxlength, an input mask, or a '
          'controlled component).'
    else if (result.value != null)
      'The field now holds exactly that.'
    else
      'The field\'s value could not be read back, so this is unverified.',
  ];

  Future<Object?> _key(Map<String, dynamic> args) async {
    final key = _requiredString(args, 'key');
    if (parseBrowserKey(key) == null) {
      throw BrowserToolException(
        'Unknown key "$key". Valid keys: $browserKeyNames.',
      );
    }
    await _service.pressKey(key);
    return _text(['Pressed $key on ${await _pageLine()}']);
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  Future<String> _pageLine() async {
    try {
      return '${await _service.currentTitle()} — ${await _service.currentUrl()}';
    } on BrowserException {
      return 'the attached page';
    }
  }

  Future<String> _whereAmI() async => 'Now on ${await _pageLine()}';

  /// A JavaScript result, compactly: a scalar as itself, a structure as JSON.
  static String _renderValue(Object? value) => switch (value) {
    null => 'null',
    final String s => s,
    final num n => '$n',
    final bool b => '$b',
    _ => const JsonEncoder.withIndent('  ').convert(value),
  };

  static String _kb(Uint8List bytes) =>
      '${(bytes.length / 1024).toStringAsFixed(1)} KB PNG';

  static Map<String, Object?> _image(Uint8List png) => {
    'type': 'image',
    'data': base64Encode(png),
    'mimeType': 'image/png',
  };

  static Map<String, Object?> _textBlock(String text) => {
    'type': 'text',
    'text': text,
  };

  /// One text block. Deliberately not a JSON map — see the class doc.
  static Object _text(List<String> lines) =>
      _content([_textBlock(lines.join('\n'))]);

  static Object _content(List<Map<String, Object?>> blocks) => {
    '_mcpContent': blocks,
  };

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _requiredString(Map<String, dynamic> args, String name) {
    final value = args[name];
    if (value is! String || value.isEmpty) {
      throw BrowserToolException('$name is required.');
    }
    return value;
  }

  static int? _int(Object? value) => (value as num?)?.round();
}
