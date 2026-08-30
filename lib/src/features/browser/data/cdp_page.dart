import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../domain/browser_failure.dart';
import '../domain/browser_target.dart';
import '../domain/cdp_message.dart';
import '../domain/element_capture.dart';
import '../domain/picked_element.dart';
import 'cdp_connection.dart';
import 'cdp_payloads.dart';
import 'picker_script.dart';

/// One attached page, driven over CDP.
///
/// Everything a caller (and, later, an MCP tool) needs: navigate, evaluate,
/// query the DOM, screenshot, and read an element's HTML plus its computed
/// styles. Nothing here reports success speculatively — every wait either
/// observes the browser confirming the outcome or raises.
class CdpPage {
  CdpPage({required this.connection, required this.target});

  final CdpConnection connection;

  /// The target this page attached to. Its `url` is the address at attach
  /// time; ask the page itself via [currentUrl] for where it is now.
  final BrowserTarget target;

  bool _domainsEnabled = false;

  /// Whether the underlying connection is still alive.
  bool get isConnected => !connection.isClosed;

  /// Enables the domains every other call depends on. Idempotent.
  Future<void> enableDomains() async {
    if (_domainsEnabled) return;
    await connection.send('Page.enable');
    await connection.send('Runtime.enable');
    await connection.send('DOM.enable');
    await connection.send('CSS.enable');
    _domainsEnabled = true;
  }

  /// Navigates to [url] and waits for the page's load event.
  ///
  /// Fails with [BrowserFailure.navigationTimeout] if the load event never
  /// arrives — a page that never finishes loading is reported as exactly that,
  /// not as a successful navigation.
  Future<void> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await enableDomains();
    // Subscribe before navigating: the load event can arrive before the
    // Page.navigate reply for a cached or trivially small document.
    final loaded = nextEvent(
      'Page.loadEventFired',
      timeout: timeout,
      detail: 'while loading $url',
      onTimeout: BrowserFailure.navigationTimeout,
    );
    final Map<String, Object?> reply;
    try {
      reply = await connection.send('Page.navigate', params: {'url': url});
    } on Object {
      unawaited(loaded.then((_) {}, onError: (Object _) {}));
      rethrow;
    }
    final errorText = reply['errorText'];
    if (errorText is String && errorText.isNotEmpty) {
      unawaited(loaded.then((_) {}, onError: (Object _) {}));
      throw BrowserException(
        BrowserFailure.protocolError,
        describeBrowserFailure(
          BrowserFailure.protocolError,
          detail: 'navigation to $url failed: $errorText',
        ),
      );
    }
    await loaded;
  }

  /// Evaluates [expression] in the page and returns its value.
  ///
  /// Uses `returnByValue`, so the result is plain JSON-compatible Dart. A
  /// thrown JavaScript error becomes [BrowserFailure.evaluationFailed].
  Future<Object?> evaluate(
    String expression, {
    bool awaitPromise = false,
    Duration? timeout,
  }) async {
    await enableDomains();
    final reply = await connection.send(
      'Runtime.evaluate',
      params: {
        'expression': expression,
        'returnByValue': true,
        'awaitPromise': awaitPromise,
        'userGesture': true,
      },
      timeout: timeout,
    );
    return unwrapEvaluateResult(reply);
  }

  /// The page's current URL, read from the page itself.
  Future<String> currentUrl() async =>
      (await evaluate('location.href'))?.toString() ?? '';

  /// The page title, read from the page itself.
  Future<String> currentTitle() async =>
      (await evaluate('document.title'))?.toString() ?? '';

  /// Resolves [selector] to a DOM node id.
  ///
  /// `DOM.getDocument` is re-issued each time: it is what makes node ids
  /// valid, and a navigation invalidates every id handed out before it.
  Future<int> querySelectorNodeId(String selector) async {
    await enableDomains();
    final document = await connection.send(
      'DOM.getDocument',
      params: {'depth': 0},
    );
    final root = (document['root'] as Map<String, Object?>?)?['nodeId'];
    if (root is! int) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'DOM.getDocument returned no root node',
        ),
      );
    }
    final Map<String, Object?> found;
    try {
      found = await connection.send(
        'DOM.querySelector',
        params: {'nodeId': root, 'selector': selector},
      );
    } on BrowserException catch (e) {
      if (e.failure != BrowserFailure.protocolError) rethrow;
      throw BrowserException(
        BrowserFailure.elementNotFound,
        describeBrowserFailure(
          BrowserFailure.elementNotFound,
          detail: 'selector `$selector` was rejected by the page',
        ),
        cause: e,
      );
    }
    final nodeId = found['nodeId'];
    if (nodeId is! int || nodeId == 0) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        describeBrowserFailure(
          BrowserFailure.elementNotFound,
          detail: 'selector `$selector`',
        ),
      );
    }
    return nodeId;
  }

  /// How many elements match [selector].
  Future<int> countMatches(String selector) async {
    final count = await evaluate(
      'document.querySelectorAll(${jsonEncode(selector)}).length',
    );
    return count is num ? count.toInt() : 0;
  }

  /// The element's `outerHTML`.
  Future<String> outerHtmlOfNode(int nodeId) async {
    final reply = await connection.send(
      'DOM.getOuterHTML',
      params: {'nodeId': nodeId},
    );
    final html = reply['outerHTML'];
    if (html is! String) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'DOM.getOuterHTML returned no markup',
        ),
      );
    }
    return html;
  }

  /// Every computed longhand property for the node.
  Future<Map<String, String>> computedStylesOfNode(int nodeId) async =>
      parseComputedStyle(
        await connection.send(
          'CSS.getComputedStyleForNode',
          params: {'nodeId': nodeId},
        ),
      );

  /// The node under a viewport coordinate, used when no selector can be
  /// derived for a picked element (shadow DOM, mostly).
  Future<int> nodeIdAtPoint(double x, double y) async {
    await enableDomains();
    await connection.send('DOM.getDocument', params: {'depth': 0});
    final located = await connection.send(
      'DOM.getNodeForLocation',
      params: {
        'x': x.round(),
        'y': y.round(),
        'includeUserAgentShadowDOM': false,
      },
    );
    final nodeId = located['nodeId'];
    if (nodeId is int && nodeId != 0) return nodeId;
    final backendNodeId = located['backendNodeId'];
    if (backendNodeId is! int) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        describeBrowserFailure(
          BrowserFailure.elementNotFound,
          detail: 'nothing at (${x.round()}, ${y.round()})',
        ),
      );
    }
    final pushed = await connection.send(
      'DOM.pushNodesByBackendIdsToFrontend',
      params: {
        'backendNodeIds': [backendNodeId],
      },
    );
    final ids = pushed['nodeIds'];
    if (ids is List && ids.isNotEmpty && ids.first is int && ids.first != 0) {
      return ids.first as int;
    }
    throw BrowserException(
      BrowserFailure.elementNotFound,
      describeBrowserFailure(
        BrowserFailure.elementNotFound,
        detail: 'the node at (${x.round()}, ${y.round()}) could not be bound',
      ),
    );
  }

  /// Captures a PNG of the whole viewport, the whole page, or a [clip].
  ///
  /// [clip] is in page coordinates; `captureBeyondViewport` makes Chrome
  /// interpret it that way and renders parts that are scrolled out of sight.
  Future<Uint8List> screenshot({
    ElementBox? clip,
    bool fullPage = false,
    Duration? timeout,
  }) async {
    await enableDomains();
    var region = clip;
    if (region == null && fullPage) region = await contentBox();
    final reply = await connection.send(
      'Page.captureScreenshot',
      params: {
        'format': 'png',
        'fromSurface': true,
        if (region != null) ...{
          'captureBeyondViewport': true,
          'clip': {
            'x': region.x,
            'y': region.y,
            'width': region.width,
            'height': region.height,
            'scale': 1,
          },
        },
      },
      timeout: timeout ?? const Duration(seconds: 30),
    );
    final data = reply['data'];
    if (data is! String) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'Page.captureScreenshot returned no image',
        ),
      );
    }
    return base64Decode(data);
  }

  /// The full scrollable content box of the document, in page coordinates.
  Future<ElementBox> contentBox() async {
    final metrics = await connection.send('Page.getLayoutMetrics');
    final size =
        (metrics['cssContentSize'] ?? metrics['contentSize'])
            as Map<String, Object?>?;
    if (size == null) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'Page.getLayoutMetrics reported no content size',
        ),
      );
    }
    final content = ElementBox.fromJson(size);
    return ElementBox(x: 0, y: 0, width: content.width, height: content.height);
  }

  /// Describes the element matching [selector] the same way a pick does.
  Future<PickedElement> describeSelector(String selector) async {
    final described = await evaluate(buildDescribeSelectorScript(selector));
    if (described is! Map) {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        describeBrowserFailure(
          BrowserFailure.elementNotFound,
          detail: 'selector `$selector`',
        ),
      );
    }
    return PickedElement.fromJson(Map<String, Object?>.from(described));
  }

  /// Captures the full bundle — HTML, computed CSS and a cropped screenshot —
  /// for the element matching [selector].
  Future<ElementCapture> captureSelector(String selector) async =>
      captureElement(await describeSelector(selector));

  /// Captures the full bundle for an already-described element.
  ///
  /// Resolves the node by selector when the page could verify one, and falls
  /// back to hit-testing the click point when it could not.
  Future<ElementCapture> captureElement(PickedElement element) async {
    final selector = element.selector;
    final int nodeId;
    if (selector != null && selector.isNotEmpty) {
      nodeId = await querySelectorNodeId(selector);
    } else if (element.clientX != null && element.clientY != null) {
      nodeId = await nodeIdAtPoint(element.clientX!, element.clientY!);
    } else {
      throw BrowserException(
        BrowserFailure.elementNotFound,
        describeBrowserFailure(
          BrowserFailure.elementNotFound,
          detail: 'the element could not be addressed by selector or position',
        ),
      );
    }

    final outerHtml = await outerHtmlOfNode(nodeId);
    final styles = await computedStylesOfNode(nodeId);
    final shot = element.box.isEmpty
        ? null
        : await screenshot(clip: element.box);

    return ElementCapture(
      selector: selector ?? '(no unique selector; picked by position)',
      tagName: element.tagName,
      elementId: element.elementId,
      classNames: element.classNames,
      outerHtml: outerHtml,
      computedStyles: styles,
      box: element.box,
      pageUrl: element.url,
      pageTitle: element.title,
      capturedAt: DateTime.now(),
      screenshotPng: shot,
    );
  }

  /// Waits for the next [method] event.
  ///
  /// If the connection dies first this fails with
  /// [BrowserFailure.disconnected] rather than hanging until the timeout —
  /// "the browser went away" must never look like "still working".
  Future<CdpEvent> nextEvent(
    String method, {
    required Duration timeout,
    required String detail,
    BrowserFailure onTimeout = BrowserFailure.timeout,
  }) {
    final completer = Completer<CdpEvent>();
    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      completer.completeError(
        BrowserException(
          onTimeout,
          describeBrowserFailure(onTimeout, detail: detail),
        ),
      );
    });
    final subscription = connection
        .on(method)
        .listen(
          (event) {
            if (!completer.isCompleted) completer.complete(event);
          },
          onDone: () {
            if (completer.isCompleted) return;
            completer.completeError(
              BrowserException(
                BrowserFailure.disconnected,
                describeBrowserFailure(
                  BrowserFailure.disconnected,
                  detail: detail,
                ),
              ),
            );
          },
        );
    return completer.future.whenComplete(() {
      timer.cancel();
      unawaited(subscription.cancel());
    });
  }

  /// Closes the connection to this page. The tab itself stays open.
  Future<void> close() => connection.close();
}
