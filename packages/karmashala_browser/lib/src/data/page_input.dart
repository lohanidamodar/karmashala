import '../domain/browser_failure.dart';
import '../domain/browser_key.dart';
import '../domain/found_element.dart';
import 'cdp_page.dart';
import 'input_script.dart';

/// Drives a page the way a person does: find something, click it, type into
/// it.
///
/// Everything here goes through `Input.dispatchMouseEvent` /
/// `Input.dispatchKeyEvent`, which enter the browser's real input pipeline and
/// fire the page's own listeners — the same event path a hand on a mouse
/// produces. Nothing sets `.value` from JavaScript and calls it typing: a
/// framework that listens for `keydown` would never see it, and the caller
/// would be told the field was filled when the app disagrees.
///
/// Targets are addressed by **selector or visible text**, never by raw
/// coordinates. A coordinate goes stale the moment the layout shifts and then
/// fails silently by hitting the wrong thing; a selector either resolves or
/// says it did not.
class PageInput {
  PageInput(this._page);

  final CdpPage _page;

  /// Elements matching a CSS [selector] or visible [text].
  ///
  /// Ranking and innermost-match selection happen in the page (see
  /// [buildFindElementsScript]); this is the Dart side of the same contract.
  Future<FindResult> find({
    String? selector,
    String? text,
    bool exact = false,
    bool visibleOnly = true,
    int limit = 25,
  }) async {
    if ((selector == null || selector.isEmpty) &&
        (text == null || text.isEmpty)) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        'Give a CSS selector or the visible text to look for.',
      );
    }
    final raw = await _page.evaluate(
      buildFindElementsScript(
        selector: selector,
        text: text,
        exact: exact,
        visibleOnly: visibleOnly,
        limit: limit,
      ),
    );
    if (raw is! Map) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'the page did not describe its elements',
        ),
      );
    }
    final error = raw['error'];
    if (error is String) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        describeBrowserFailure(BrowserFailure.elementNotFound, detail: error),
      );
    }
    return FindResult(
      total: (raw['total'] as num?)?.toInt() ?? 0,
      hidden: (raw['hidden'] as num?)?.toInt() ?? 0,
      elements: [
        for (final element in (raw['elements'] as List? ?? const []))
          if (element is Map)
            FoundElement.fromJson(Map<String, Object?>.from(element)),
      ],
      query: _describeQuery(selector: selector, text: text, exact: exact),
    );
  }

  /// Clicks the element matching [selector] or [text].
  ///
  /// Refuses rather than guessing when the query is ambiguous (pass [index]),
  /// when the element is scrolled out of reach, or when something else covers
  /// the point — in which case the covering element is named. A click that
  /// lands on a cookie banner and reports success is the failure this whole
  /// method is arranged to prevent.
  Future<ClickResult> click({
    String? selector,
    String? text,
    bool exact = false,
    int? index,
    int clickCount = 1,
  }) async {
    final target = await _resolveOne(
      selector: selector,
      text: text,
      exact: exact,
      index: index,
      verb: 'click',
    );
    final resolved = target.element.selector;
    if (resolved == null) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        'The element matching ${target.query} has no selector that resolves '
        'back to it (it is probably inside a shadow root), so it cannot be '
        'clicked reliably. Pick it in the browser pane, or click a parent '
        'that does have one.',
      );
    }

    final prepared = await _page.evaluate(buildClickTargetScript(resolved));
    if (prepared is! Map) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'the page did not report a point to click',
        ),
      );
    }
    final element = _element(prepared['element']) ?? target.element;
    if (prepared['ok'] != true) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        _clickRefusal(prepared, element, resolved),
      );
    }
    final x = (prepared['x'] as num).toDouble();
    final y = (prepared['y'] as num).toDouble();
    await _dispatchClick(x, y, clickCount: clickCount);
    return ClickResult(
      element: element,
      x: x,
      y: y,
      candidates: target.candidates,
    );
  }

  /// Types [text] with real key events, optionally clicking a field first.
  ///
  /// Per-character `keyDown`/`keyUp` rather than one bulk insert: a page that
  /// filters on `keydown` (a search box, a numeric-only field, an autocomplete)
  /// behaves the same way for us as for a person.
  Future<TypeResult> type(
    String text, {
    String? selector,
    String? targetText,
    bool exact = false,
    int? index,
    bool submit = false,
  }) async {
    FoundElement? field;
    if ((selector != null && selector.isNotEmpty) ||
        (targetText != null && targetText.isNotEmpty)) {
      final clicked = await click(
        selector: selector,
        text: targetText,
        exact: exact,
        index: index,
      );
      field = clicked.element;
    }
    for (final rune in text.runes) {
      await _typeCharacter(String.fromCharCode(rune));
    }
    if (submit) await pressKey('enter');
    final active =
        field ?? _element(await _page.evaluate(buildActiveElementScript()));
    final resolved = active?.selector;
    return TypeResult(
      element: active,
      text: text,
      value: resolved == null ? null : await _readField(resolved),
      submitted: submit,
    );
  }

  /// Replaces a field's contents with [value].
  ///
  /// Focus, select everything already there, then insert — so the field ends
  /// up holding exactly [value] and not [value] appended to a default. The
  /// value is **read back afterwards**, and [TypeResult.matches] says whether
  /// the page kept what we sent (a maxlength or an input mask may not).
  Future<TypeResult> fill({
    String? selector,
    String? text,
    bool exact = false,
    int? index,
    required String value,
    bool submit = false,
  }) async {
    final target = await _resolveOne(
      selector: selector,
      text: text,
      exact: exact,
      index: index,
      verb: 'fill',
    );
    final resolved = target.element.selector;
    if (resolved == null) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        'The field matching ${target.query} has no selector that resolves back '
        'to it, so it cannot be filled reliably.',
      );
    }

    final prepared = await _page.evaluate(
      buildPrepareFieldScript(resolved, value),
    );
    if (prepared is! Map) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'the page did not report the state of the field',
        ),
      );
    }
    final element = _element(prepared['element']) ?? target.element;
    if (prepared['ok'] != true) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        _fillRefusal(prepared, element),
      );
    }

    if (prepared['mode'] == 'select') {
      if (submit) await pressKey('enter');
      return TypeResult(
        element: element,
        text: value,
        value: prepared['value']?.toString(),
        submitted: submit,
      );
    }

    if (value.isEmpty) {
      // Nothing to insert; the selection has to be deleted explicitly or the
      // old value survives and we would report an empty field that is not.
      await pressKey('delete');
    } else {
      await _page.connection.send('Input.insertText', params: {'text': value});
    }
    if (submit) await pressKey('enter');
    return TypeResult(
      element: element,
      text: value,
      value: await _readField(resolved),
      submitted: submit,
    );
  }

  /// Presses a named key — `enter`, `tab`, `escape`, `arrowDown`…
  Future<void> pressKey(String name) async {
    final key = parseBrowserKey(name);
    if (key == null) {
      throw BrowserException(
        BrowserFailure.protocolError,
        'Unknown key "$name". Valid keys: $browserKeyNames.',
      );
    }
    await _page.connection.send(
      'Input.dispatchKeyEvent',
      params: key.params('keyDown'),
    );
    await _page.connection.send(
      'Input.dispatchKeyEvent',
      params: key.params('keyUp'),
    );
  }

  /// Scrolls the page (or an element) by a wheel gesture.
  Future<void> scrollBy({double dx = 0, double dy = 0}) async {
    final metrics = await _page.evaluate(
      '({x: window.innerWidth / 2, y: window.innerHeight / 2})',
    );
    final centre = metrics is Map ? metrics : const {};
    await _page.connection.send(
      'Input.dispatchMouseEvent',
      params: {
        'type': 'mouseWheel',
        'x': (centre['x'] as num?)?.toDouble() ?? 10,
        'y': (centre['y'] as num?)?.toDouble() ?? 10,
        'deltaX': dx,
        'deltaY': dy,
      },
    );
  }

  Future<String?> _readField(String selector) async {
    final value = await _page.evaluate(buildReadFieldScript(selector));
    return value?.toString();
  }

  Future<void> _typeCharacter(String character) async {
    if (character == '\n' || character == '\r') {
      await pressKey('enter');
      return;
    }
    if (character == '\t') {
      await pressKey('tab');
      return;
    }
    final params = {
      'key': character,
      'text': character,
      'unmodifiedText': character,
    };
    await _page.connection.send(
      'Input.dispatchKeyEvent',
      params: {'type': 'keyDown', ...params},
    );
    await _page.connection.send(
      'Input.dispatchKeyEvent',
      params: {'type': 'keyUp', 'key': character},
    );
  }

  Future<void> _dispatchClick(double x, double y, {int clickCount = 1}) async {
    await _page.connection.send(
      'Input.dispatchMouseEvent',
      params: {
        'type': 'mouseMoved',
        'x': x,
        'y': y,
        'button': 'none',
        'buttons': 0,
      },
    );
    for (var press = 1; press <= clickCount; press++) {
      await _page.connection.send(
        'Input.dispatchMouseEvent',
        params: {
          'type': 'mousePressed',
          'x': x,
          'y': y,
          'button': 'left',
          'buttons': 1,
          'clickCount': press,
        },
      );
      await _page.connection.send(
        'Input.dispatchMouseEvent',
        params: {
          'type': 'mouseReleased',
          'x': x,
          'y': y,
          'button': 'left',
          'buttons': 0,
          'clickCount': press,
        },
      );
    }
  }

  /// Picks the one element a verb should act on, or explains why it will not.
  Future<_Target> _resolveOne({
    String? selector,
    String? text,
    required bool exact,
    required int? index,
    required String verb,
  }) async {
    final found = await find(
      selector: selector,
      text: text,
      exact: exact,
      limit: index == null ? 12 : index + 1,
    );
    if (found.elements.isEmpty) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        found.hidden > 0
            ? 'Nothing visible matches ${found.query}; ${found.hidden} '
                  'match${found.hidden == 1 ? '' : 'es'} but '
                  '${found.hidden == 1 ? 'is' : 'are'} hidden, so there is '
                  'nothing to $verb.'
            : 'Nothing matches ${found.query}, so there is nothing to $verb.',
      );
    }
    if (index != null) {
      if (index < 0 || index >= found.elements.length) {
        throw BrowserException(
          BrowserFailure.elementNotFound,
          'index $index is out of range: ${found.query} matches '
          '${found.total} element${found.total == 1 ? '' : 's'}.',
        );
      }
      return _Target(found.elements[index], found.total, found.query);
    }
    if (found.elements.length > 1) {
      // Several matches. A text query that produced exactly one *exact*,
      // interactive match is still a decision we can make; anything else is a
      // guess, and a wrong click is worse than an error because the caller
      // cannot tell it happened.
      final best = found.elements.first;
      final ambiguous = found.elements
          .skip(1)
          .where(
            (other) =>
                other.text.toLowerCase() == best.text.toLowerCase() &&
                other.interactive == best.interactive,
          )
          .isNotEmpty;
      if (ambiguous || selector != null) {
        throw BrowserException(
          BrowserFailure.elementNotFound,
          '${found.query} matches ${found.total} elements. Pass index to '
          'choose one, or narrow the query:\n${found.indexedListing()}',
        );
      }
    }
    return _Target(found.elements.first, found.total, found.query);
  }

  FoundElement? _element(Object? raw) =>
      raw is Map ? FoundElement.fromJson(Map<String, Object?>.from(raw)) : null;

  String _clickRefusal(
    Map<Object?, Object?> prepared,
    FoundElement element,
    String selector,
  ) => switch (prepared['reason']) {
    'gone' =>
      'The element `$selector` disappeared between finding it and clicking '
          'it. The page probably re-rendered; look again.',
    'empty' =>
      '${element.description} (`$selector`) has no rendered area, so there is '
          'nowhere to click. It may be hidden or collapsed.',
    'offscreen' =>
      '${element.description} (`$selector`) is still outside the viewport '
          'after scrolling to it — it may be inside a scroll container of its '
          'own. Scroll it into view first.',
    'covered' =>
      'Clicking ${element.description} (`$selector`) would land on '
          '${_element(prepared['blocker'])?.description ?? 'another element'} '
          'instead: something is covering it (an overlay, a modal, or a '
          'cookie banner). Dismiss it first.',
    _ => 'The element `$selector` could not be clicked.',
  };

  String _fillRefusal(Map<Object?, Object?> prepared, FoundElement element) =>
      switch (prepared['reason']) {
        'gone' =>
          'The field disappeared before it could be filled; look again.',
        'nooption' =>
          'That <select> has no such option. Its options are: '
              '${(prepared['options'] as List? ?? const []).join(', ')}.',
        'notext' =>
          '${element.description} is an <input type="${prepared['type']}">, '
              'which holds no text. Use a click for it instead.',
        'noteditable' =>
          '${element.description} is not a text field or a contenteditable, '
              'so it cannot be filled.',
        'disabled' => '${element.description} is disabled.',
        'readonly' => '${element.description} is read-only.',
        _ => '${element.description} could not be filled.',
      };

  String _describeQuery({
    String? selector,
    String? text,
    required bool exact,
  }) => selector != null && selector.isNotEmpty
      ? 'selector `$selector`'
      : 'text ${exact ? 'exactly ' : ''}"$text"';
}

/// What a search found: the matches, plus what was left out.
class FindResult {
  const FindResult({
    required this.total,
    required this.hidden,
    required this.elements,
    required this.query,
  });

  /// How many elements matched, before the visibility filter and the limit.
  final int total;

  /// How many matches were dropped for being invisible.
  final int hidden;
  final List<FoundElement> elements;

  /// The query, phrased for a message ("selector `#go`" / 'text "Sign in"').
  final String query;

  /// The matches numbered, so a caller can pass `index`.
  String indexedListing({int max = 12}) => [
    for (var i = 0; i < elements.length && i < max; i++)
      '[$i] ${elements[i].toListing()}',
  ].join('\n');
}

class _Target {
  const _Target(this.element, this.candidates, this.query);
  final FoundElement element;
  final int candidates;
  final String query;
}
