import 'dart:async';

import '../domain/cdp_message.dart';
import '../domain/page_diagnostics.dart';
import 'cdp_page.dart';

/// Listens to a page's own complaints — console errors and failed requests.
/// Passive: it subscribes and never sends a command that changes the page, and
/// bounded, because a page in a redirect loop emits thousands a minute.
class PageObserver {
  PageObserver({this.limit = 200});

  CdpPage? _page;

  /// The page currently being watched, or null before [watch].
  CdpPage? get page => _page;

  /// How many of each kind are kept. The first [limit] are kept, not the last:
  /// the *first* error is the one that explains the rest.
  final int limit;

  final _subscriptions = <StreamSubscription<CdpEvent>>[];
  final _console = <ConsoleMessage>[];
  final _network = <NetworkFailure>[];
  final _seen = <String>{};

  /// requestId → (method, url), so a `loadingFailed` can name what failed.
  /// Bounded the same way, because a long-lived page never stops making them.
  final _requests = <String, ({String method, String url})>{};

  var _consoleDropped = 0;
  var _networkDropped = 0;

  List<ConsoleMessage> get consoleMessages => List.unmodifiable(_console);
  List<NetworkFailure> get networkFailures => List.unmodifiable(_network);

  /// How many were seen past [limit] and not kept, per kind.
  int get consoleDropped => _consoleDropped;
  int get networkDropped => _networkDropped;

  bool get isEmpty => _console.isEmpty && _network.isEmpty;

  /// Points the collector at [page]. Safe to call again after a reconnect: what
  /// was already collected is kept, which is why one observer follows the
  /// session rather than being replaced with it.
  Future<void> watch(CdpPage page) async {
    await stop();
    _page = page;
    await page.enableDomains();
    await page.connection.send('Log.enable');
    await page.connection.send('Network.enable');
    _listen('Runtime.consoleAPICalled', _onConsoleApi);
    _listen('Runtime.exceptionThrown', _onExceptionThrown);
    _listen('Log.entryAdded', _onLogEntry);
    _listen('Network.requestWillBeSent', _onRequestWillBeSent);
    _listen('Network.responseReceived', _onResponseReceived);
    _listen('Network.loadingFailed', _onLoadingFailed);
  }

  /// Stops listening. What was collected stays readable afterwards — the run
  /// writes its evidence file after it has stopped watching.
  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  void _listen(String method, void Function(Map<String, Object?>) handler) {
    final page = _page;
    if (page == null) return;
    _subscriptions.add(
      page.connection.on(method).listen((event) {
        // A malformed event must never take the run down: losing one line of
        // evidence is better than losing the run.
        try {
          handler(event.params);
        } on Object {
          // Ignored deliberately.
        }
      }),
    );
  }

  void _onConsoleApi(Map<String, Object?> params) {
    final type = params['type'] as String?;
    final level = switch (type) {
      'error' || 'assert' => 'error',
      'warning' => 'warning',
      _ => null,
    };
    if (level == null) return;
    final args = params['args'];
    final text = args is List
        ? args.map(_describeRemoteObject).where((s) => s.isNotEmpty).join(' ')
        : '';
    if (text.isEmpty) return;
    _addConsole(
      ConsoleMessage(
        level: level,
        text: text,
        source: _firstFrame(params['stackTrace']),
        at: DateTime.now().toUtc(),
      ),
    );
  }

  void _onExceptionThrown(Map<String, Object?> params) {
    final details = params['exceptionDetails'];
    if (details is! Map) return;
    final exception = details['exception'];
    final described = exception is Map ? exception['description'] : null;
    final text = (described ?? details['text'] ?? 'Uncaught exception')
        .toString();
    final url = details['url'];
    final line = details['lineNumber'];
    _addConsole(
      ConsoleMessage(
        level: 'error',
        text: text,
        source: url is String && url.isNotEmpty
            ? (line is num ? '$url:${line.toInt() + 1}' : url)
            : _firstFrame(details['stackTrace']),
        at: DateTime.now().toUtc(),
      ),
    );
  }

  void _onLogEntry(Map<String, Object?> params) {
    final entry = params['entry'];
    if (entry is! Map) return;
    final level = entry['level'];
    if (level != 'error' && level != 'warning') return;
    // A failed request arrives here *and* on Network.loadingFailed; keeping both
    // listed one fault twice, which reads as two bugs. This one is the console.
    if (entry['source'] == 'network') return;
    final text = entry['text'];
    if (text is! String || text.isEmpty) return;
    final url = entry['url'];
    final line = entry['lineNumber'];
    _addConsole(
      ConsoleMessage(
        level: level! as String,
        text: text,
        source: url is String && url.isNotEmpty
            ? (line is num ? '$url:${line.toInt() + 1}' : url)
            : null,
        at: DateTime.now().toUtc(),
      ),
    );
  }

  void _addConsole(ConsoleMessage message) {
    if (!_seen.add(message.fingerprint)) return;
    if (_console.length >= limit) {
      _consoleDropped++;
      return;
    }
    _console.add(message);
  }

  void _onRequestWillBeSent(Map<String, Object?> params) {
    final id = params['requestId'];
    final request = params['request'];
    if (id is! String || request is! Map) return;
    if (_requests.length > 2000) _requests.clear();
    _requests[id] = (
      method: (request['method'] ?? 'GET').toString(),
      url: (request['url'] ?? '').toString(),
    );
  }

  void _onResponseReceived(Map<String, Object?> params) {
    final response = params['response'];
    if (response is! Map) return;
    final status = response['status'];
    if (status is! num || status < 400) return;
    final id = params['requestId'];
    final known = id is String ? _requests[id] : null;
    _addNetwork(
      NetworkFailure(
        url: (response['url'] ?? known?.url ?? '').toString(),
        method: known?.method,
        status: status.toInt(),
        at: DateTime.now().toUtc(),
      ),
    );
  }

  void _onLoadingFailed(Map<String, Object?> params) {
    // A cancelled request is not a failure — navigating away cancels whatever
    // was in flight, and reporting that as evidence would make every run noisy.
    if (params['canceled'] == true) return;
    final id = params['requestId'];
    final known = id is String ? _requests[id] : null;
    final url = known?.url ?? '';
    if (url.isEmpty) return;
    _addNetwork(
      NetworkFailure(
        url: url,
        method: known?.method,
        errorText: (params['errorText'] ?? 'request failed').toString(),
        at: DateTime.now().toUtc(),
      ),
    );
  }

  void _addNetwork(NetworkFailure failure) {
    if (!_seen.add('net:${failure.fingerprint}')) return;
    if (_network.length >= limit) {
      _networkDropped++;
      return;
    }
    _network.add(failure);
  }

  /// A remote object as one short string. Chrome sends a value for primitives
  /// and only a description for everything else.
  static String _describeRemoteObject(Object? arg) {
    if (arg is! Map) return '';
    final value = arg['value'];
    if (value != null) return value.toString();
    final description = arg['description'];
    if (description is String) return description;
    final preview = arg['preview'];
    if (preview is Map && preview['description'] is String) {
      return preview['description']! as String;
    }
    final type = arg['type'];
    return type is String ? '[$type]' : '';
  }

  /// `url:line:column` of the innermost frame, when there is a stack.
  static String? _firstFrame(Object? stackTrace) {
    if (stackTrace is! Map) return null;
    final frames = stackTrace['callFrames'];
    if (frames is! List || frames.isEmpty) return null;
    final frame = frames.first;
    if (frame is! Map) return null;
    final url = frame['url'];
    if (url is! String || url.isEmpty) return null;
    final line = frame['lineNumber'];
    return line is num ? '$url:${line.toInt() + 1}' : url;
  }
}
