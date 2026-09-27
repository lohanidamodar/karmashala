import 'dart:async';
import 'dart:io';

import 'package:karmashala_browser/browser.dart';

import 'fake_cdp_socket.dart';

/// A real (1x1, transparent) PNG.
const String kTinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
    'hQGAhKmMIQAAAABJRU5ErkJggg==';

/// What the picker's binding reports when a person clicks an element.
const String kPickPayload =
    '{"ok":true,"selector":"#hero","tagName":"section","id":"hero",'
    '"classNames":["banner"],"box":{"x":0,"y":0,"width":320,"height":180},'
    '"url":"https://example.com/app","title":"Example"}';

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

/// A DevTools endpoint with scripted targets. [listening] false until a
/// launch: the first probe says nothing is there, so the launcher spawns.
class ScriptedEndpoint extends DevToolsHttpEndpoint {
  ScriptedEndpoint({
    super.port = 9222,
    required this.targets,
    this.listening = true,
  });

  List<BrowserTarget> targets;

  /// Thrown by [openTab] when set: a browser that will not open a page.
  Object? openTabError;
  bool listening;

  @override
  Future<DevToolsEndpointState> probe() async => listening
      ? DevToolsEndpointState.available
      : DevToolsEndpointState.notListening;

  @override
  Future<List<BrowserTarget>> listTargets() async => targets;

  @override
  Future<BrowserTarget> openTab(String url) async {
    if (openTabError case final error?) throw error;
    final target = fakeTarget('NEW', url: url);
    targets = [...targets, target];
    return target;
  }

  @override
  void close() {}
}

/// A scriptable [BrowserProcess]: [killed] once the server ends it.
class FakeBrowserProcess implements BrowserProcess {
  final _exit = Completer<int>();
  bool killed = false;

  @override
  Stream<String> get stdoutLines => const Stream.empty();

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> kill() async {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(137);
  }
}

/// A [BrowserService] over a fake Chrome: CDP answered in Dart, no process
/// ever started. With [spawn], nothing listens until the "launch", so the
/// session is one the server spawned, on a throwaway profile under [temp].
class FakeBrowser {
  FakeBrowser({
    List<BrowserTarget>? targets,
    bool spawn = false,
    this.temp,
    Duration? pickTimeout,
  }) : endpoint = ScriptedEndpoint(
         targets: targets ?? [fakeTarget('PAGE-1')],
         listening: !spawn,
       ) {
    Future<BrowserProcess> start(String executable, List<String> args) async {
      starts.add(args);
      endpoint.listening = true;
      return process;
    }

    service = _TimeboxedBrowserService(
      pickTimeout: pickTimeout,
      startProcess: start,
      launcher: BrowserLauncher(
        startProcess: start,
        locateExecutable: () => '/fake/chrome',
        endpointFactory: (_) => endpoint,
        createUserDataDir: () async {
          final directory = (temp ?? Directory.systemTemp).createTempSync(
            'fake-cdp-profile-',
          );
          profiles.add(directory);
          return directory.path;
        },
        pollInterval: const Duration(milliseconds: 1),
      ),
      connectSocket: (_) async {
        final created = _buildSocket();
        sockets.add(created);
        return created;
      },
    );
  }

  final ScriptedEndpoint endpoint;
  final Directory? temp;
  final process = FakeBrowserProcess();
  final starts = <List<String>>[];
  final profiles = <Directory>[];
  final List<FakeCdpSocket> sockets = [];
  late final BrowserService service;

  /// Answers `Runtime.evaluate`.
  Object? Function(String expression)? onEvaluate = _defaultEvaluate;

  static Object? _defaultEvaluate(String expression) {
    if (expression.contains('__karmashalaPicker')) return true;
    if (expression == 'location.href') return 'https://example.com/app';
    if (expression == 'document.title') return 'Example';
    return null;
  }

  FakeCdpSocket get socket => sockets.last;

  List<Map<String, Object?>> framesFor(String method) => [
    for (final frame in socket.sentFrames)
      if (frame['method'] == method)
        (frame['params'] as Map<String, Object?>?) ?? const {},
  ];

  /// A person clicks the element [kPickPayload] describes.
  void click() => socket.emitEvent('Runtime.bindingCalled', {
    'name': '__karmashalaPick',
    'payload': kPickPayload,
  });

  FakeCdpSocket _buildSocket() {
    final created = FakeCdpSocket();
    created.responder = (method, params) {
      if (method == 'Page.navigate') {
        scheduleMicrotask(() => created.emitEvent('Page.loadEventFired'));
        return {'frameId': 'F1'};
      }
      if (method == 'Runtime.evaluate') {
        final value = onEvaluate?.call(params['expression']! as String);
        return {
          'result': {'type': 'object', 'value': value},
        };
      }
      return switch (method) {
        'DOM.getDocument' => {
          'root': {'nodeId': 1},
        },
        'DOM.querySelector' => {'nodeId': 42},
        'DOM.getOuterHTML' => {'outerHTML': '<section id="hero"></section>'},
        'CSS.getComputedStyleForNode' => {
          'computedStyle': [
            {'name': 'display', 'value': 'block'},
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
