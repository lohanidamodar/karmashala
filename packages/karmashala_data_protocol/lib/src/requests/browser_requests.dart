part of '../data_request.dart';

// The browser, driven by the server over CDP (slice 3d): a Chrome on the
// server's machine — the person's own window beside a local server, a
// headless one on a box. Every client's pane shows `BrowserStateChanged`
// and asks through these; each waits on the browser, so each is answered
// when done. A request that fails is refused in the browser taxonomy's words.

DataRequest<Object?>? _browserRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      BrowserStateGet.name => const BrowserStateGet(),
      BrowserConnect.name => BrowserConnect(
        spawn: args.boolean('spawn', orElse: true),
        url: args.optionalString('url'),
      ),
      BrowserDisconnect.name => const BrowserDisconnect(),
      BrowserNavigate.name => BrowserNavigate(args.string('url')),
      BrowserTabs.name => const BrowserTabs(),
      BrowserSelectTab.name => BrowserSelectTab(args.string('targetId')),
      BrowserScreenshot.name => const BrowserScreenshot(),
      BrowserPickElement.name => const BrowserPickElement(),
      BrowserCancelPick.name => const BrowserCancelPick(),
      BrowserEvaluate.name => BrowserEvaluate(args.string('expression')),
      BrowserFind.name => BrowserFind(
        selector: args.optionalString('selector'),
        text: args.optionalString('text'),
        limit: args.optionalInt('limit') ?? 10,
      ),
      _ => null,
    };

/// Work the server does with its browser.
sealed class BrowserWorkRequest<R> extends DataRequest<R> {
  const BrowserWorkRequest();
}

/// A request answered with the browser's state after it.
sealed class BrowserStateRequest extends BrowserWorkRequest<BrowserState> {
  const BrowserStateRequest();

  @override
  Object? resultToJson(BrowserState result) => result.toJson();

  @override
  BrowserState resultFromJson(Object? json) =>
      _decode(kind, () => BrowserState.fromJson(_object(json, kind)));
}

/// The browser as it stands.
final class BrowserStateGet extends BrowserStateRequest {
  const BrowserStateGet();

  static const String name = 'browser.state';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};
}

/// Attaches to the browser on the server's port, launching one when [spawn]
/// and nothing listens — at [url] when given.
final class BrowserConnect extends BrowserStateRequest {
  const BrowserConnect({this.spawn = true, this.url});

  static const String name = 'browser.connect';

  final bool spawn;
  final String? url;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'spawn': spawn, 'url': ?url};
}

/// Lets go of the page. A browser the server launched keeps running until
/// the server stops.
final class BrowserDisconnect extends BrowserStateRequest {
  const BrowserDisconnect();

  static const String name = 'browser.disconnect';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};
}

/// Goes to [url], connecting first when nothing is attached.
final class BrowserNavigate extends BrowserStateRequest {
  const BrowserNavigate(this.url);

  static const String name = 'browser.navigate';

  final String url;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'url': url};
}

/// Reads the tab list again.
final class BrowserTabs extends BrowserStateRequest {
  const BrowserTabs();

  static const String name = 'browser.tabs';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};
}

/// Drives tab [targetId] instead.
final class BrowserSelectTab extends BrowserStateRequest {
  const BrowserSelectTab(this.targetId);

  static const String name = 'browser.select';

  final String targetId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'targetId': targetId};
}

/// A picture of the viewport, PNG.
final class BrowserScreenshot extends BrowserWorkRequest<Uint8List> {
  const BrowserScreenshot();

  static const String name = 'browser.screenshot';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(Uint8List result) => pngToJson(result);

  @override
  Uint8List resultFromJson(Object? json) =>
      _decode(kind, () => pngFromJson(json));
}

/// Hands the page to a person to click an element in, and answers it.
/// Refused on a headless server: there is no window to click in.
final class BrowserPickElement extends BrowserWorkRequest<BrowserPick> {
  const BrowserPickElement();

  static const String name = 'browser.pick';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(BrowserPick result) => result.toJson();

  @override
  BrowserPick resultFromJson(Object? json) =>
      _decode(kind, () => BrowserPick.fromJson(_object(json, kind)));
}

/// Stops a pick in progress.
final class BrowserCancelPick extends BrowserWorkRequest<DataAck> {
  const BrowserCancelPick();

  static const String name = 'browser.cancelPick';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Evaluates [expression] in the page, for the person at a pane (an agent's
/// `browser_evaluate` is consent-gated; this is not). Answers the value as
/// text.
final class BrowserEvaluate extends BrowserWorkRequest<String> {
  const BrowserEvaluate(this.expression);

  static const String name = 'browser.evaluate';

  final String expression;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'expression': expression};

  @override
  Object? resultToJson(String result) => result;

  @override
  String resultFromJson(Object? json) =>
      json is String ? json : _badAnswer(kind);
}

/// Finds elements by CSS [selector] or visible [text]; answers the listing
/// as text, at most [limit] matches.
final class BrowserFind extends BrowserWorkRequest<String> {
  const BrowserFind({this.selector, this.text, this.limit = 10});

  static const String name = 'browser.find';

  final String? selector;
  final String? text;
  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'selector': ?selector,
    'text': ?text,
    'limit': limit,
  };

  @override
  Object? resultToJson(String result) => result;

  @override
  String resultFromJson(Object? json) =>
      json is String ? json : _badAnswer(kind);
}
