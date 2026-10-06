/// The HTML artifact sandbox, measured in a real Chromium — the engine behind
/// WebView2 on Windows and the Android system web view. The shell is set as
/// the document of an `about:blank` page, as a web view's load-from-string
/// does; the artifact's script then tries every way out and reports what it
/// got on the console, and a loopback server counts anything that left.
///
/// Launches its own headless browser on a throwaway profile and a port of its
/// own choosing (never 9222, never the person's profile). Skips itself when
/// no Chrome or Edge is installed. Run it deliberately:
///   dart test --tags=live test/live/artifact_sandbox_live_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_browser/browser.dart' show locateChromeExecutable;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final chrome = locateChromeExecutable();

  late Directory profile;
  late Process browser;
  late WebSocket cdp;
  late HttpServer leaks;
  final hits = <String>[];
  final console = <String>[];
  var nextId = 0;
  final pending = <int, Completer<Map<String, Object?>>>{};

  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = ++nextId;
    final done = pending[id] = Completer();
    cdp.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return done.future.timeout(const Duration(seconds: 15));
  }

  setUp(() async {
    hits.clear();
    console.clear();
    leaks = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    leaks.listen((request) {
      hits.add(request.uri.path);
      request.response
        ..headers.contentType = ContentType.html
        ..write('<p>leaked</p>')
        ..close();
    });
    profile = await Directory.systemTemp.createTemp('ks-sandbox-chrome');
    browser = await Process.start(chrome!, [
      '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=${profile.path}',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      'about:blank',
    ]);
    final portFile = File(p.join(profile.path, 'DevToolsActivePort'));
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    int? port;
    while (port == null) {
      if (DateTime.now().isAfter(deadline)) fail('Chrome never opened CDP');
      try {
        final lines = portFile.readAsLinesSync();
        port = lines.isEmpty ? null : int.tryParse(lines.first.trim());
      } on FileSystemException {
        // Not written yet, or still held by Chrome.
      }
      if (port == null) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final client = HttpClient();
    final listing = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/json/list'),
    )).close();
    final pages = (jsonDecode(await utf8.decodeStream(listing)) as List)
        .cast<Map<String, Object?>>()
        .where((t) => t['type'] == 'page')
        .toList();
    client.close();
    cdp = await WebSocket.connect(pages.first['webSocketDebuggerUrl']! as String);
    cdp.listen((raw) {
      final message = jsonDecode(raw as String) as Map<String, Object?>;
      final id = message['id'];
      if (id is int) {
        pending.remove(id)?.complete(message);
        return;
      }
      // Chromium puts a sandboxed frame in a process of its own: its console
      // is heard on a session attached to it.
      if (message['method'] == 'Target.attachedToTarget') {
        final session = (message['params']! as Map)['sessionId'];
        for (final method in [
          'Runtime.enable',
          'Runtime.runIfWaitingForDebugger',
        ]) {
          cdp.add(
            jsonEncode({
              'id': ++nextId,
              'sessionId': session,
              'method': method,
            }),
          );
        }
        return;
      }
      if (message['method'] == 'Runtime.consoleAPICalled') {
        final args = (message['params']! as Map)['args'] as List;
        console.add(
          args.map((a) => (a as Map)['value']?.toString() ?? '').join(' '),
        );
      }
    });
    await send('Runtime.enable');
    await send('Page.enable');
    await send('Target.setAutoAttach', {
      'autoAttach': true,
      'waitForDebuggerOnStart': false,
      'flatten': true,
    });
  });

  tearDown(() async {
    await cdp.close();
    browser.kill();
    await browser.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    await leaks.close(force: true);
    try {
      await profile.delete(recursive: true);
    } on FileSystemException {
      // Chrome may hold a file a moment longer; the temp folder is ours.
    }
  });

  /// Shows [html] in the sandbox and waits for its `DONE` line.
  Future<Map<String, String>> run(
    String html, {
    bool network = false,
  }) async {
    final shell = artifactSandboxShell(html, allowNetwork: network);
    await send('Page.navigate', {
      'url': 'data:text/html;base64,${base64Encode(utf8.encode(shell))}',
    });
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!console.any((line) => line.startsWith('DONE'))) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the artifact never reported; console: $console');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Give a navigation or beacon that slipped out time to arrive.
    await Future<void>.delayed(const Duration(seconds: 2));
    return {
      for (final line in console)
        if (line.contains('=')) line.split('=').first: line.split('=').last,
    };
  }

  test(
    'the artifact runs, but reaches no parent, file, network or window',
    () async {
      final secret = File(p.join(profile.path, 'secret.txt'))
        ..writeAsStringSync('do not read');
      final origin = 'http://127.0.0.1:${leaks.port}';
      final results = await run('''
<p id="x">hello</p>
<script>
  const say = (k, v) => console.log(k + '=' + v);
  const tryIt = async (k, f) => {
    try { const r = await f(); say(k, r === undefined ? 'ok' : String(r)); }
    catch (e) { say(k, 'blocked'); }
  };
  (async () => {
    say('ran', document.getElementById('x').textContent);
    say('origin', String(window.origin));
    await tryIt('parent', () => parent.document.body.innerHTML);
    await tryIt('top', () => { top.location.href = '$origin/top'; });
    await tryIt('fetch', () => fetch('$origin/fetch').then(r => r.status));
    await tryIt('file', () => fetch('${Uri.file(secret.path)}').then(r => r.text()));
    await tryIt('xhr', () => new Promise((ok, no) => {
      const x = new XMLHttpRequest(); x.open('GET', '$origin/xhr');
      x.onload = () => ok(x.status); x.onerror = () => no(); x.send();
    }));
    say('popup', String(window.open('$origin/popup')));
    const img = new Image(); img.src = '$origin/img';
    navigator.sendBeacon && navigator.sendBeacon('$origin/beacon', 'x');
    await tryIt('storage', () => localStorage.setItem('k', 'v'));
    await tryIt('cookie', () => { document.cookie = 'a=b'; return document.cookie; });
    say('bridge', typeof window.flutter_inappwebview);
    say('DONE', '1');
    setTimeout(() => { location.href = '$origin/self'; }, 50);
    const f = document.createElement('iframe');
    f.src = '$origin/nested'; document.body.appendChild(f);
  })();
</script>
''');
      expect(results['ran'], 'hello', reason: 'scripts must run');
      expect(results['origin'], 'null', reason: 'an opaque origin');
      expect(results['parent'], 'blocked');
      expect(results['fetch'], 'blocked');
      expect(results['file'], 'blocked');
      expect(results['xhr'], 'blocked');
      expect(results['popup'], 'null');
      expect(results['storage'], 'blocked');
      expect(results['bridge'], 'undefined');
      expect(hits, isEmpty, reason: 'nothing may leave: $hits');
    },
    skip: chrome == null ? 'no Chrome or Edge on this machine' : false,
  );

  test(
    'with the network allowed, plain http and files are still refused',
    () async {
      final origin = 'http://127.0.0.1:${leaks.port}';
      final results = await run('''
<script>
  const say = (k, v) => console.log(k + '=' + v);
  fetch('$origin/fetch').then(() => say('fetch', 'ok'), () => say('fetch', 'blocked'))
    .then(() => fetch('file:///C:/Windows/win.ini').then(() => say('file', 'ok'), () => say('file', 'blocked')))
    .then(() => say('DONE', '1'));
</script>
''', network: true);
      expect(results['fetch'], 'blocked');
      expect(results['file'], 'blocked');
      expect(hits, isEmpty);
    },
    skip: chrome == null ? 'no Chrome or Edge on this machine' : false,
  );
}

