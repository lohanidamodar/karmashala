import 'dart:convert';
import 'dart:io';

import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

/// Answers like Chrome's `/json/*` endpoint, so the HTTP half of the client is
/// exercised over a real socket rather than a mock.
Future<HttpServer> startFakeDevTools({
  List<Map<String, Object?>> targets = const [],
  bool devTools = true,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final path = request.uri.path;
    request.response.headers.contentType = ContentType.json;
    if (path == '/json/version') {
      request.response.write(
        devTools
            ? jsonEncode({
                'Browser': 'Chrome/128.0.0.0',
                'webSocketDebuggerUrl': 'ws://127.0.0.1/devtools/browser/abc',
              })
            : 'this is a dev server, not chrome',
      );
    } else if (path == '/json/list') {
      request.response.write(jsonEncode(targets));
    } else if (path == '/json/new') {
      if (request.method != 'PUT') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else {
        request.response.write(
          jsonEncode({
            'id': 'NEW',
            'type': 'page',
            'title': '',
            'url': Uri.decodeComponent(request.uri.query),
            'webSocketDebuggerUrl': 'ws://127.0.0.1/devtools/page/NEW',
          }),
        );
      }
    } else if (path == '/json/close/BOOM') {
      request.response.statusCode = HttpStatus.internalServerError;
    } else if (path.startsWith('/json/close/')) {
      request.response.write('Target is closing');
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  return server;
}

/// A port nothing is listening on.
Future<int> freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

void main() {
  group('probe', () {
    test('a real DevTools endpoint is available', () async {
      final server = await startFakeDevTools();
      final endpoint = DevToolsHttpEndpoint(port: server.port);
      expect(await endpoint.probe(), DevToolsEndpointState.available);
      endpoint.close();
      await server.close(force: true);
    });

    test(
      'an unrelated server on the port is not mistaken for Chrome',
      () async {
        final server = await startFakeDevTools(devTools: false);
        final endpoint = DevToolsHttpEndpoint(port: server.port);
        expect(await endpoint.probe(), DevToolsEndpointState.occupiedByOther);
        endpoint.close();
        await server.close(force: true);
      },
    );

    test('a refused connection means nothing is listening', () async {
      final endpoint = DevToolsHttpEndpoint(port: await freePort());
      expect(await endpoint.probe(), DevToolsEndpointState.notListening);
      endpoint.close();
    });
  });

  group('listTargets', () {
    test('parses the target list', () async {
      final server = await startFakeDevTools(
        targets: [
          {
            'id': 'A',
            'type': 'page',
            'title': 'Example',
            'url': 'https://example.com',
            'webSocketDebuggerUrl': 'ws://127.0.0.1/devtools/page/A',
          },
        ],
      );
      final endpoint = DevToolsHttpEndpoint(port: server.port);
      final targets = await endpoint.listTargets();
      expect(targets.single.id, 'A');
      expect(targets.single.isDrivablePage, isTrue);
      endpoint.close();
      await server.close(force: true);
    });

    test('reports notRunning when the browser has gone', () async {
      final endpoint = DevToolsHttpEndpoint(port: await freePort());
      await expectLater(
        endpoint.listTargets(),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.failure,
            'failure',
            BrowserFailure.notRunning,
          ),
        ),
      );
      endpoint.close();
    });
  });

  group('openTab', () {
    test('opens a tab with PUT, as Chrome 111+ requires', () async {
      final server = await startFakeDevTools();
      final endpoint = DevToolsHttpEndpoint(port: server.port);
      final target = await endpoint.openTab('https://example.com/a?b=c');
      expect(target.id, 'NEW');
      expect(target.url, 'https://example.com/a?b=c');
      endpoint.close();
      await server.close(force: true);
    });
  });

  test('closeTab addresses the target by id', () async {
    final server = await startFakeDevTools();
    final endpoint = DevToolsHttpEndpoint(port: server.port);
    await endpoint.closeTab('A');
    endpoint.close();
    await server.close(force: true);
  });

  test('an HTTP error status is reported, not swallowed', () async {
    final server = await startFakeDevTools();
    final endpoint = DevToolsHttpEndpoint(port: server.port);
    await expectLater(
      endpoint.closeTab('BOOM'),
      throwsA(
        isA<BrowserException>()
            .having((e) => e.failure, 'failure', BrowserFailure.protocolError)
            .having((e) => e.message, 'message', contains('HTTP 500')),
      ),
    );
    endpoint.close();
    await server.close(force: true);
  });

  test('a server that never answers times out', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((_) {});
    final endpoint = DevToolsHttpEndpoint(
      port: server.port,
      timeout: const Duration(milliseconds: 100),
    );
    expect(await endpoint.probe(), DevToolsEndpointState.occupiedByOther);
    endpoint.close();
    await server.close(force: true);
  });
}
