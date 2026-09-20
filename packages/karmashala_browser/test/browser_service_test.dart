import 'dart:async';
import 'dart:convert';

import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

import 'fake_cdp_socket.dart';
import 'support/fake_browser_process.dart';

BrowserTarget page(String id, {String url = 'https://example.com'}) =>
    BrowserTarget(
      id: id,
      type: 'page',
      title: 'Example',
      url: url,
      webSocketDebuggerUrl: 'ws://127.0.0.1:9222/devtools/page/$id',
    );

/// A [DevToolsHttpEndpoint] whose target list is scripted.
class FakeEndpoint extends DevToolsHttpEndpoint {
  FakeEndpoint({
    super.port = 9222,
    this.targets = const [],
    this.state = DevToolsEndpointState.available,
  });

  List<BrowserTarget> targets;
  DevToolsEndpointState state;
  String? openedUrl;
  bool wasClosed = false;

  @override
  Future<DevToolsEndpointState> probe() async => state;

  @override
  Future<List<BrowserTarget>> listTargets() async => targets;

  @override
  Future<BrowserTarget> openTab(String url) async {
    openedUrl = url;
    final target = page('NEW', url: url);
    targets = [...targets, target];
    return target;
  }

  @override
  void close() => wasClosed = true;
}

Matcher failsWith(BrowserFailure failure) => throwsA(
  isA<BrowserException>().having((e) => e.failure, 'failure', failure),
);

/// The service plus the doubles behind it. [socket] is the most recently
/// opened one, since reconnecting opens a fresh socket.
class Fixture {
  Fixture({
    required this.service,
    required this.endpoint,
    required this.sockets,
  });
  final BrowserService service;
  final FakeEndpoint endpoint;
  final List<FakeCdpSocket> sockets;
  FakeCdpSocket get socket => sockets.last;
}

FakeCdpSocket buildSocket() {
  final socket = FakeCdpSocket();
  socket.responder = (method, params) {
    if (method == 'Page.navigate') {
      scheduleMicrotask(() => socket.emitEvent('Page.loadEventFired'));
      return {'frameId': 'F1'};
    }
    return switch (method) {
      'Runtime.evaluate' => {
        'result': {
          'type': 'object',
          'value': {
            'ok': true,
            'selector': '#go',
            'tagName': 'button',
            'box': {'x': 1, 'y': 2, 'width': 3, 'height': 4},
            'url': 'https://example.com',
            'title': 'Example',
          },
        },
      },
      'DOM.getDocument' => {
        'root': {'nodeId': 1},
      },
      'DOM.querySelector' => {'nodeId': 42},
      'DOM.getOuterHTML' => {'outerHTML': '<button id="go">Go</button>'},
      'CSS.getComputedStyleForNode' => {'computedStyle': <Object?>[]},
      'Page.captureScreenshot' => {
        'data': base64Encode([7, 7]),
      },
      _ => <String, Object?>{},
    };
  };
  return socket;
}

Fixture build({List<BrowserTarget> targets = const []}) {
  final endpoint = FakeEndpoint(targets: targets);
  final sockets = <FakeCdpSocket>[];
  final service = BrowserService(
    startProcess: FakeProcessStarter().call,
    launcher: BrowserLauncher(
      startProcess: FakeProcessStarter().call,
      locateExecutable: () => r'C:\chrome.exe',
      endpointFactory: (_) => endpoint,
      createUserDataDir: () async => r'C:\Temp\profile',
      pollInterval: const Duration(milliseconds: 1),
    ),
    connectSocket: (_) async {
      final socket = buildSocket();
      sockets.add(socket);
      return socket;
    },
  );
  return Fixture(service: service, endpoint: endpoint, sockets: sockets);
}

void main() {
  group('connect', () {
    test(
      'attaches to the first drivable page and enables the domains',
      () async {
        final fixture = build(targets: [page('A')]);
        final session = await fixture.service.connect();
        expect(session.page.target.id, 'A');
        expect(fixture.socket.methods.take(4), [
          'Page.enable',
          'Runtime.enable',
          'DOM.enable',
          'CSS.enable',
        ]);
        expect(fixture.service.isConnected, isTrue);
        await fixture.service.disconnect();
      },
    );

    test('skips targets that are not drivable pages', () async {
      final fixture = build(
        targets: [
          const BrowserTarget(
            id: 'SW',
            type: 'service_worker',
            title: '',
            url: 'https://example.com/sw.js',
            webSocketDebuggerUrl: 'ws://x',
          ),
          page('A'),
        ],
      );
      final session = await fixture.service.connect();
      expect(session.page.target.id, 'A');
      await fixture.service.disconnect();
    });

    test('attaches to a named target when asked', () async {
      final fixture = build(targets: [page('A'), page('B')]);
      final session = await fixture.service.connect(targetId: 'B');
      expect(session.page.target.id, 'B');
      await fixture.service.disconnect();
    });

    test('an unknown target id is reported, not quietly replaced', () async {
      final fixture = build(targets: [page('A')]);
      await expectLater(
        fixture.service.connect(targetId: 'ZZZ'),
        failsWith(BrowserFailure.noTarget),
      );
      expect(fixture.endpoint.wasClosed, isTrue);
    });

    test(
      'a browser with no page and no url asked for reports noTarget',
      () async {
        final fixture = build();
        await expectLater(
          fixture.service.connect(),
          failsWith(BrowserFailure.noTarget),
        );
      },
    );

    test('a browser with no page opens one when a url was asked for', () async {
      final fixture = build();
      final session = await fixture.service.connect(
        url: 'https://example.com/start',
      );
      expect(fixture.endpoint.openedUrl, 'https://example.com/start');
      expect(session.page.target.id, 'NEW');
      await fixture.service.disconnect();
    });

    test('an existing tab is navigated to the requested url', () async {
      final fixture = build(targets: [page('A', url: 'https://old.example')]);
      await fixture.service.connect(url: 'https://new.example');
      expect(fixture.socket.paramsFor('Page.navigate'), {
        'url': 'https://new.example',
      });
      await fixture.service.disconnect();
    });

    test('a tab already at the url is not navigated again', () async {
      final fixture = build(targets: [page('A', url: 'https://example.com')]);
      await fixture.service.connect(url: 'https://example.com');
      expect(fixture.socket.methods, isNot(contains('Page.navigate')));
      await fixture.service.disconnect();
    });

    test('a page another debugger already owns is reported', () async {
      final fixture = build(
        targets: const [
          BrowserTarget(
            id: 'BUSY',
            type: 'page',
            title: '',
            url: 'https://example.com',
            webSocketDebuggerUrl: null,
          ),
        ],
      );
      await expectLater(
        fixture.service.connect(),
        failsWith(BrowserFailure.noTarget),
      );
    });

    test(
      'a page that refuses to enable its domains has its socket closed',
      () async {
        // The socket was left open on this path: to the browser the page stayed
        // "being debugged", and the next connect was refused for it.
        final endpoint = FakeEndpoint(targets: [page('A')]);
        late FakeCdpSocket socket;
        final service = BrowserService(
          startProcess: FakeProcessStarter().call,
          launcher: BrowserLauncher(
            startProcess: FakeProcessStarter().call,
            locateExecutable: () => r'C:\chrome.exe',
            endpointFactory: (_) => endpoint,
            createUserDataDir: () async => r'C:\Temp\profile',
          ),
          connectSocket: (_) async {
            socket = FakeCdpSocket(
              responder: (method, _) {
                if (method == 'Page.enable') throw CdpFault(-32601, 'no Page');
                return <String, Object?>{};
              },
            );
            return socket;
          },
        );

        await expectLater(
          service.connect(),
          failsWith(BrowserFailure.protocolError),
        );
        expect(socket.closed, isTrue);
        expect(endpoint.wasClosed, isTrue);
        expect(service.session, isNull);
      },
    );

    test('connecting again replaces the previous session', () async {
      final fixture = build(targets: [page('A')]);
      final first = await fixture.service.connect();
      await fixture.service.connect();
      expect(first.page.connection.isClosed, isTrue);
      await fixture.service.disconnect();
    });
  });

  group('using the session', () {
    test('captures an element bundle through the page', () async {
      final fixture = build(targets: [page('A')]);
      await fixture.service.connect();
      final capture = await fixture.service.capture('#go');
      expect(capture.outerHtml, '<button id="go">Go</button>');
      expect(capture.screenshotPng, [7, 7]);
      await fixture.service.disconnect();
    });

    test('a selector screenshot clips to that element', () async {
      final fixture = build(targets: [page('A')]);
      await fixture.service.connect();
      await fixture.service.screenshot(selector: '#go');
      expect(fixture.socket.paramsFor('Page.captureScreenshot')!['clip'], {
        'x': 1.0,
        'y': 2.0,
        'width': 3.0,
        'height': 4.0,
        'scale': 1,
      });
      await fixture.service.disconnect();
    });

    test('a plain screenshot has no clip', () async {
      final fixture = build(targets: [page('A')]);
      await fixture.service.connect();
      await fixture.service.screenshot();
      expect(
        fixture.socket.paramsFor('Page.captureScreenshot')!.containsKey('clip'),
        isFalse,
      );
      await fixture.service.disconnect();
    });

    test('listTargets and openTab go through the endpoint', () async {
      final fixture = build(targets: [page('A')]);
      await fixture.service.connect();
      expect(await fixture.service.listTargets(), hasLength(1));
      await fixture.service.openTab('https://example.com/two');
      expect(fixture.endpoint.openedUrl, 'https://example.com/two');
      await fixture.service.disconnect();
    });
  });

  group('nothing to talk to', () {
    test('every verb refuses before a connection', () async {
      final fixture = build();
      for (final call in <Future<Object?> Function()>[
        () => fixture.service.navigate('https://example.com'),
        () => fixture.service.evaluate('1'),
        () => fixture.service.capture('#go'),
        () => fixture.service.screenshot(),
        () => fixture.service.countMatches('.x'),
        () => fixture.service.listTargets(),
        () => fixture.service.openTab('https://example.com'),
        () => fixture.service.pickElement(),
      ]) {
        await expectLater(call(), failsWith(BrowserFailure.notRunning));
      }
      expect(fixture.service.isConnected, isFalse);
      expect(fixture.service.cancelPick, returnsNormally);
    });

    test('a call after the browser went away reports disconnected', () async {
      final fixture = build(targets: [page('A')]);
      await fixture.service.connect();
      fixture.socket.drop();
      await pumpEventQueue();
      expect(fixture.service.isConnected, isFalse);
      await expectLater(
        fixture.service.evaluate('1'),
        failsWith(BrowserFailure.disconnected),
      );
    });

    test('disconnect releases the socket and the http client', () async {
      final fixture = build(targets: [page('A')]);
      await fixture.service.connect();
      await fixture.service.disconnect();
      expect(fixture.socket.closed, isTrue);
      expect(fixture.endpoint.wasClosed, isTrue);
      expect(fixture.service.session, isNull);
    });

    test('disconnecting twice is harmless', () async {
      final fixture = build(targets: [page('A')]);
      await fixture.service.connect();
      await fixture.service.disconnect();
      await expectLater(fixture.service.disconnect(), completes);
    });
  });
}
