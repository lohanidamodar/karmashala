import 'dart:async';

import 'package:karmashala/src/features/browser/application/browser_providers.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import 'fake_cdp_socket.dart';

/// A real (1x1, transparent) PNG, so a widget under test can actually decode
/// the screenshot instead of logging an image error.
const String kTinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
    'hQGAhKmMIQAAAABJRU5ErkJggg==';

/// A page target, as `/json/list` would report it.
BrowserTarget fakeTarget(
  String id, {
  String url = 'https://example.com',
  String title = 'Example',
}) => BrowserTarget(
  id: id,
  type: 'page',
  title: title,
  url: url,
  webSocketDebuggerUrl: 'ws://127.0.0.1:9222/devtools/page/$id',
);

/// A [DevToolsHttpEndpoint] whose target list is scripted.
class ScriptedEndpoint extends DevToolsHttpEndpoint {
  ScriptedEndpoint({super.port = 9222, this.targets = const []});

  List<BrowserTarget> targets;
  String? openedUrl;

  @override
  Future<DevToolsEndpointState> probe() async =>
      DevToolsEndpointState.available;

  @override
  Future<List<BrowserTarget>> listTargets() async => targets;

  @override
  Future<BrowserTarget> openTab(String url) async {
    openedUrl = url;
    final target = fakeTarget('NEW', url: url);
    targets = [...targets, target];
    return target;
  }

  @override
  void close() {}
}

Matcher failsWith(BrowserFailure failure) => throwsA(
  isA<BrowserException>().having((e) => e.failure, 'failure', failure),
);

/// A connected [BrowserService] whose page answers whatever the test says.
///
/// [onEvaluate] receives the actual JavaScript we send, so a test asserts on
/// the real script and not on a stand-in for it: if the wrong script is built,
/// the fake does not recognise it and the test fails.
class FakeBrowser {
  FakeBrowser({
    this.onEvaluate,
    List<BrowserTarget>? targets,
    Duration? pickTimeout,
  }) : endpoint = ScriptedEndpoint(targets: targets ?? [fakeTarget('PAGE-1')]) {
    service = _TimeboxedBrowserService(
      pickTimeout: pickTimeout,
      startProcess: browserProcessStarter(FakeCommandRunner()),
      launcher: BrowserLauncher(
        startProcess: browserProcessStarter(FakeCommandRunner()),
        locateExecutable: () => r'C:\chrome.exe',
        endpointFactory: (_) => endpoint,
        createUserDataDir: () async => r'C:\Temp\profile',
        pollInterval: const Duration(milliseconds: 1),
      ),
      connectSocket: (_) async {
        final created = _buildSocket();
        sockets.add(created);
        return created;
      },
    );
  }

  /// Answers `Runtime.evaluate`. Return `_unhandled` (the default) to fall
  /// back to the generic replies below.
  Object? Function(String expression)? onEvaluate;

  final ScriptedEndpoint endpoint;
  final List<FakeCdpSocket> sockets = [];
  late final BrowserService service;

  FakeCdpSocket get socket => sockets.last;

  /// Frames sent for [method], in order.
  List<Map<String, Object?>> framesFor(String method) => [
    for (final frame in socket.sentFrames)
      if (frame['method'] == method)
        (frame['params'] as Map<String, Object?>?) ?? const {},
  ];

  /// The JavaScript expressions the service evaluated, in order.
  List<String> get expressions => [
    for (final params in framesFor('Runtime.evaluate'))
      params['expression']! as String,
  ];

  Future<BrowserSession> connect() => service.connect();

  FakeCdpSocket _buildSocket() {
    final created = FakeCdpSocket();
    created.responder = (method, params) {
      if (method == 'Page.navigate') {
        scheduleMicrotask(() => created.emitEvent('Page.loadEventFired'));
        return {'frameId': 'F1'};
      }
      if (method == 'Runtime.evaluate') {
        final expression = params['expression']! as String;
        final value = onEvaluate?.call(expression);
        return {
          'result': {'type': 'object', 'value': value},
        };
      }
      return switch (method) {
        'DOM.getDocument' => {
          'root': {'nodeId': 1},
        },
        'DOM.querySelector' => {'nodeId': 42},
        'DOM.getOuterHTML' => {'outerHTML': '<button id="go">Go</button>'},
        'CSS.getComputedStyleForNode' => {
          'computedStyle': [
            {'name': 'background-color', 'value': 'rgb(1, 2, 3)'},
            {'name': 'display', 'value': 'inline-block'},
          ],
        },
        'Page.captureScreenshot' => {'data': kTinyPngBase64},
        'Page.getLayoutMetrics' => {
          'cssContentSize': {'x': 0, 'y': 0, 'width': 800, 'height': 600},
        },
        _ => <String, Object?>{},
      };
    };
    return created;
  }
}

/// A [BrowserService] whose pick gives up after [pickTimeout] rather than the
/// two minutes a person gets, so the "nobody clicked" branch is reachable from
/// a test without a two-minute wait.
class _TimeboxedBrowserService extends BrowserService {
  _TimeboxedBrowserService({
    required this.pickTimeout,
    required super.startProcess,
    super.launcher,
    super.connectSocket,
  });

  final Duration? pickTimeout;

  @override
  Future<ElementCapture> pickElement({
    Duration timeout = const Duration(minutes: 2),
  }) => super.pickElement(timeout: pickTimeout ?? timeout);
}

/// One element in the shape the page's describe() reports.
Map<String, Object?> describedElement({
  String tagName = 'button',
  String? selector = '#go',
  String? id = 'go',
  List<String> classNames = const [],
  String text = 'Go',
  bool visible = true,
  bool interactive = true,
  bool inViewport = true,
  bool disabled = false,
  double x = 10,
  double y = 20,
  double width = 100,
  double height = 30,
}) => {
  'selector': selector,
  'tagName': tagName,
  'id': id,
  'classNames': classNames,
  'text': text,
  'visible': visible,
  'interactive': interactive,
  'inViewport': inViewport,
  'disabled': disabled,
  'centerX': x + width / 2,
  'centerY': y + height / 2,
  'box': {'x': x, 'y': y, 'width': width, 'height': height},
};

/// What the find script returns.
Map<String, Object?> findReply(
  List<Map<String, Object?>> elements, {
  int? total,
  int hidden = 0,
}) => {
  'total': total ?? elements.length,
  'hidden': hidden,
  'elements': elements,
};

/// What the click-target script returns when the click may proceed.
Map<String, Object?> clickReply({
  Map<String, Object?>? element,
  double x = 60,
  double y = 35,
}) => {'ok': true, 'element': element ?? describedElement(), 'x': x, 'y': y};

/// Recognises which of our scripts an expression is, so a fake can answer the
/// right one without matching the whole source.
enum PageScript {
  find,
  clickTarget,
  prepareField,
  readField,
  activeElement,
  describeSelector,
}

PageScript? scriptKind(String expression) {
  if (expression.contains('return {ok:true,selector:')) {
    return PageScript.describeSelector;
  }
  if (expression.contains('elementFromPoint')) return PageScript.clickTarget;
  if (expression.contains('uneditableInput')) return PageScript.prepareField;
  if (expression.contains('var NEEDLE')) return PageScript.find;
  if (expression.contains('el.isContentEditable')) return PageScript.readField;
  if (expression.contains('document.activeElement')) {
    return PageScript.activeElement;
  }
  return null;
}

/// What `buildDescribeSelectorScript` returns — the picker's payload shape.
Map<String, Object?> describeSelectorReply({
  String selector = '#go',
  String tagName = 'button',
}) => {
  'ok': true,
  'selector': selector,
  'tagName': tagName,
  'id': 'go',
  'classNames': const <String>[],
  'box': {'x': 10.0, 'y': 20.0, 'width': 100.0, 'height': 30.0},
  'url': 'https://example.com/app',
  'title': 'Example',
};
