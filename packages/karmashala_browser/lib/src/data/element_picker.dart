import 'dart:async';
import 'dart:convert';

import '../domain/browser_failure.dart';
import '../domain/cdp_message.dart';
import '../domain/element_capture.dart';
import '../domain/picked_element.dart';
import 'cdp_page.dart';
import 'picker_script.dart';

/// Drives the in-page element picker and turns a click into an
/// [ElementCapture].
///
/// The mechanism: `Runtime.addBinding` installs a function on the page's
/// global object, the injected script calls it on click, and the browser
/// surfaces that as a `Runtime.bindingCalled` event on our socket. No polling.
class ElementPicker {
  ElementPicker(this._page, {this.bindingName = kPickerBindingName});

  final CdpPage _page;
  final String bindingName;

  Completer<PickOutcome>? _pending;

  /// Whether a pick is currently waiting on the user.
  bool get isActive => _pending != null;

  /// Highlights elements on hover and resolves with the one the user clicks.
  ///
  /// Fails with [BrowserFailure.pickCancelled] on Escape,
  /// [BrowserFailure.targetGone] if the page navigates away underneath the
  /// picker, and [BrowserFailure.disconnected] if the browser is closed.
  Future<ElementCapture> pick({
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (isActive) {
      throw BrowserException(
        BrowserFailure.protocolError,
        describeBrowserFailure(
          BrowserFailure.protocolError,
          detail: 'an element pick is already in progress',
        ),
      );
    }
    await _page.enableDomains();
    // Raise the tab before arming anything. A pick is a request for a click in
    // another window, and until now nothing put that window in front of the
    // user — the pane said "Click an element in the browser…" and then waited
    // two minutes on a page they might not be looking at.
    //
    // `Page.bringToFront` rather than the `/json/activate/<id>` sibling on
    // `DevToolsHttpEndpoint`: the picker already holds this connection and not
    // that endpoint, and ordering on one socket is what makes "forward, then
    // armed" a fact rather than a hope. What it activates is the *target*; how
    // far its window rises above ours is the platform's decision, not a thing
    // this client observes.
    await _page.connection.send('Page.bringToFront');

    final completer = Completer<PickOutcome>();
    _pending = completer;
    Timer? timer;
    final subscriptions = <StreamSubscription<CdpEvent>>[];

    void fail(BrowserException error) {
      if (!completer.isCompleted) completer.completeError(error);
    }

    try {
      subscriptions.add(
        _page.connection.on('Runtime.bindingCalled').listen(
          (event) {
            if (event.params['name'] != bindingName) return;
            final payload = event.params['payload'];
            if (payload is! String) return;
            try {
              final decoded = jsonDecode(payload);
              if (decoded is! Map<String, Object?>) return;
              if (!completer.isCompleted) {
                completer.complete(parsePickPayload(decoded));
              }
            } on FormatException catch (e) {
              fail(
                BrowserException(
                  BrowserFailure.malformedResponse,
                  describeBrowserFailure(
                    BrowserFailure.malformedResponse,
                    detail: 'the picker reported an unreadable selection',
                  ),
                  cause: e,
                ),
              );
            }
          },
          onDone: () => fail(
            BrowserException(
              BrowserFailure.disconnected,
              describeBrowserFailure(
                BrowserFailure.disconnected,
                detail: 'while picking an element',
              ),
            ),
          ),
        ),
      );

      // A navigation destroys the context holding the injected script, so the
      // click that would have ended this pick can never arrive. Say so instead
      // of waiting out the timeout.
      subscriptions.add(
        _page.connection.on('Page.frameNavigated').listen((event) {
          final frame = event.params['frame'];
          if (frame is! Map || frame['parentId'] != null) return;
          fail(
            BrowserException(
              BrowserFailure.targetGone,
              describeBrowserFailure(
                BrowserFailure.targetGone,
                detail:
                    'the page navigated to '
                    '${frame['url'] ?? 'another address'} while picking',
              ),
            ),
          );
        }),
      );
      subscriptions.add(
        _page.connection
            .on('Inspector.targetCrashed')
            .listen(
              (_) => fail(
                BrowserException(
                  BrowserFailure.targetGone,
                  describeBrowserFailure(
                    BrowserFailure.targetGone,
                    detail: 'the page crashed while picking',
                  ),
                ),
              ),
            ),
      );

      await _page.connection.send(
        'Runtime.addBinding',
        params: {'name': bindingName},
      );
      final injected = await _page.evaluate(
        buildPickerScript(bindingName: bindingName),
      );
      if (injected != true) {
        throw BrowserException(
          BrowserFailure.evaluationFailed,
          describeBrowserFailure(
            BrowserFailure.evaluationFailed,
            detail: 'the picker script did not install',
          ),
        );
      }

      timer = Timer(timeout, () {
        fail(
          BrowserException(
            BrowserFailure.timeout,
            describeBrowserFailure(
              BrowserFailure.timeout,
              detail: 'no element was picked',
            ),
          ),
        );
      });

      final outcome = await completer.future;
      if (outcome is PickCancelled) {
        throw BrowserException(
          BrowserFailure.pickCancelled,
          describeBrowserFailure(BrowserFailure.pickCancelled),
        );
      }
      return await _page.captureElement((outcome as PickSelected).element);
    } finally {
      timer?.cancel();
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      _pending = null;
      await _cleanUp();
    }
  }

  /// Tears down a pick in progress; the pending [pick] fails as cancelled.
  ///
  /// The injected script's own `stop()` is deliberately silent — it only
  /// dismantles — so cancellation has to be signalled here rather than waiting
  /// for a report that will never come.
  void cancel() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    pending.complete(const PickCancelled());
  }

  /// Removes the binding and the injected script.
  ///
  /// Best effort by design: if the browser is already gone there is nothing to
  /// clean up, and the caller is being told about that failure anyway.
  Future<void> _cleanUp() async {
    if (_page.connection.isClosed) return;
    try {
      await _page.evaluate(buildPickerStopScript());
      await _page.connection.send(
        'Runtime.removeBinding',
        params: {'name': bindingName},
      );
    } on BrowserException {
      // The page went away mid-teardown; nothing left to remove.
    }
  }
}
