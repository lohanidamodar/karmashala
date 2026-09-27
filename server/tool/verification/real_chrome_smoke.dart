// Manual verification harness — NOT part of `flutter test`.
//
// Drives a real Chrome end to end and checks that what we capture is really
// what was picked. Run it from server/ with a Chrome installed:
//
//   dart run tool/verification/real_chrome_smoke.dart
//
// It spawns its own Chrome on port 9333 with a throwaway profile, exercises
// navigate / evaluate / screenshot / element picking (driven by synthetic CDP
// input, so the page's real listeners fire), decodes the returned PNGs, and
// then walks every failure mode. Exit code 0 means every check passed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_host/src/browser/server_browser.dart'
    show browserProcessStarter;

import 'png_reader.dart';

const int kPort = 9333;
const String kRed = '#dc2626';
const String kBlue = '#2563eb';
const String kGreen = '#16a34a';

int _failures = 0;

void check(String label, bool ok, [String? detail]) {
  final mark = ok ? 'PASS' : 'FAIL';
  if (!ok) _failures++;
  stdout.writeln('  [$mark] $label${detail == null ? '' : ' — $detail'}');
}

Future<void> main() async {
  final page = await _writeTestPage();
  final service = BrowserService(
    startProcess: browserProcessStarter(const LocalCommandRunner()),
  );
  BrowserProcess? chrome;

  try {
    stdout.writeln('\n== connect ==');
    final session = await service.connect(
      port: kPort,
      url: page,
      navigationTimeout: const Duration(seconds: 20),
    );
    chrome = session.endpoint.process;
    stdout.writeln('  ${session.endpoint.description}');
    check(
      'nothing was listening, so a browser was spawned',
      session.endpoint.mode == BrowserConnectionMode.spawned,
      session.endpoint.mode.name,
    );
    check(
      'the spawned browser uses a throwaway profile, not the real one',
      session.endpoint.userDataDir?.contains('karmashala-cdp-profile') ?? false,
      session.endpoint.userDataDir,
    );

    // Reconnecting must attach to the browser that is now listening rather
    // than starting a second one — attach is the preferred path.
    final reattached = await service.connect(port: kPort);
    check(
      'reconnecting attaches instead of spawning again',
      reattached.endpoint.mode == BrowserConnectionMode.attached,
      reattached.endpoint.description,
    );

    stdout.writeln('\n== navigate + evaluate ==');
    check(
      'page url is the test page',
      (await service.evaluate(
        'location.href',
      )).toString().endsWith('cdp-smoke.html'),
    );
    check(
      'title reads back',
      await service.evaluate('document.title') == 'CDP smoke',
    );
    final dpr = (await service.evaluate('window.devicePixelRatio') as num)
        .toDouble();
    stdout.writeln('  devicePixelRatio = $dpr');
    check('arithmetic evaluates', await service.evaluate('1 + 1') == 2);
    check(
      'a throwing expression reports evaluationFailed',
      await _failsWith(
        BrowserFailure.evaluationFailed,
        () => service.evaluate('throw new Error("boom")'),
      ),
    );
    check(
      'querySelectorAll counting works',
      await service.countMatches('.box') == 2,
      'light-DOM boxes only; the third lives in a shadow root',
    );

    stdout.writeln('\n== capture by selector (in viewport) ==');
    final red = await service.capture('#red-box');
    _checkCapture(red, id: 'red-box', colour: kRed, dpr: dpr);

    stdout.writeln('\n== capture by selector (scrolled far out of view) ==');
    final blue = await service.capture('#blue-box');
    check(
      'page-coordinate box is below the fold',
      blue.box.y > 1500,
      'y=${blue.box.y}',
    );
    _checkCapture(blue, id: 'blue-box', colour: kBlue, dpr: dpr);

    stdout.writeln('\n== pick: click the red box ==');
    final pickedRed = await _pickByClicking(service, '#red-box');
    check(
      'selector matches what was clicked',
      pickedRed.selector == '#red-box',
      pickedRed.selector,
    );
    _checkCapture(pickedRed, id: 'red-box', colour: kRed, dpr: dpr);
    await _checkPickerRemoved(service);

    stdout.writeln('\n== pick: scroll down, click the blue box ==');
    await service.evaluate(
      "document.querySelector('#blue-box')"
      ".scrollIntoView({block:'center'})",
    );
    final pickedBlue = await _pickByClicking(service, '#blue-box');
    check(
      'selector matches what was clicked',
      pickedBlue.selector == '#blue-box',
      pickedBlue.selector,
    );
    check(
      'picked box keeps page coordinates',
      pickedBlue.box.y > 1500,
      'y=${pickedBlue.box.y}',
    );
    _checkCapture(pickedBlue, id: 'blue-box', colour: kBlue, dpr: dpr);

    stdout.writeln('\n== pick: an element inside a shadow root ==');
    await service.evaluate('window.scrollTo(0, 0)');
    final pickedShadow = await _pickByClicking(
      service,
      "document.querySelector('#shadow-host').shadowRoot"
      ".querySelector('#shadow-inner')",
      isExpression: true,
    );
    check(
      'no unique selector, so the coordinate fallback was used',
      !pickedShadow.selector.startsWith('#'),
      pickedShadow.selector,
    );
    check(
      'outerHTML is the shadow element',
      pickedShadow.outerHtml.contains('shadow-inner'),
      pickedShadow.tagName,
    );
    check(
      'computed colour matches the shadow element',
      _rgbToHex(pickedShadow.computedStyles['background-color']) == kGreen,
      pickedShadow.computedStyles['background-color'],
    );
    _checkScreenshot(pickedShadow, kGreen, dpr);

    stdout.writeln('\n== picker teardown ==');
    await _checkPickerRemoved(service);

    stdout.writeln('\n== cancelling a pick ==');
    final cancelled = service.pickElement(timeout: const Duration(seconds: 10));
    unawaited(cancelled.then((_) {}, onError: (Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    service.cancelPick();
    check(
      'Escape-style cancel reports pickCancelled',
      await _failsWith(BrowserFailure.pickCancelled, () => cancelled),
    );
    await _checkPickerRemoved(service);

    stdout.writeln('\n== the page navigates away while picking ==');
    final orphaned = service.pickElement(timeout: const Duration(seconds: 15));
    unawaited(orphaned.then((_) {}, onError: (Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    unawaited(service.navigate('about:blank').catchError((Object _) {}));
    check(
      'a navigation under the picker reports targetGone',
      await _failsWith(BrowserFailure.targetGone, () => orphaned),
    );
    await service.navigate(page);

    stdout.writeln('\n== failure modes ==');
    check(
      'a selector that matches nothing reports elementNotFound',
      await _failsWith(
        BrowserFailure.elementNotFound,
        () => service.capture('#does-not-exist'),
      ),
    );

    final hang = await _startHangingServer();
    check(
      'a page that never finishes loading reports navigationTimeout',
      await _failsWith(
        BrowserFailure.navigationTimeout,
        () => service.navigate(
          'http://127.0.0.1:${hang.port}/hang',
          timeout: const Duration(seconds: 4),
        ),
      ),
    );
    await hang.close(force: true);

    final idle = BrowserService(
      startProcess: browserProcessStarter(const LocalCommandRunner()),
    );
    check(
      'nothing listening + no spawn reports notRunning',
      await _failsWith(
        BrowserFailure.notRunning,
        () => idle.connect(port: 9411, spawnIfNeeded: false),
      ),
    );

    final squatter = await HttpServer.bind('127.0.0.1', 9412);
    squatter.listen((request) {
      request.response
        ..write('this is not devtools')
        ..close();
    });
    check(
      'a non-DevTools server on the port reports portInUse',
      await _failsWith(
        BrowserFailure.portInUse,
        () => idle.connect(port: 9412),
      ),
    );
    await squatter.close(force: true);

    stdout.writeln('\n== the browser goes away mid-session ==');
    await service.navigate(page);
    final closing = service.evaluate(
      'new Promise(r => setTimeout(r, 60000))',
      awaitPromise: true,
    );
    unawaited(closing.then((_) {}, onError: (Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await chrome?.kill();
    check(
      'an in-flight call reports disconnected, not success',
      await _failsWith(BrowserFailure.disconnected, () => closing),
    );
    check('the service knows it is disconnected', !service.isConnected);
    check(
      'a later call reports disconnected too',
      await _failsWith(
        BrowserFailure.disconnected,
        () => service.evaluate('1'),
      ),
    );
    chrome = null;
  } finally {
    await chrome?.kill();
    await service.disconnect().catchError((Object _) {});
  }

  stdout.writeln(
    _failures == 0 ? '\nAll checks passed.' : '\n$_failures check(s) FAILED.',
  );
  exit(_failures == 0 ? 0 : 1);
}

void _checkCapture(
  ElementCapture capture, {
  required String id,
  required String colour,
  required double dpr,
}) {
  check(
    'outerHTML is the right element',
    capture.outerHtml.contains('id="$id"'),
    capture.description,
  );
  check(
    'computed background-color matches the element',
    _rgbToHex(capture.computedStyles['background-color']) == colour,
    capture.computedStyles['background-color'],
  );
  check(
    'the full computed style came back',
    capture.computedStyles.length > 100,
    '${capture.computedStyles.length} properties',
  );
  _checkScreenshot(capture, colour, dpr);
}

void _checkScreenshot(ElementCapture capture, String colour, double dpr) {
  final bytes = capture.screenshotPng;
  if (bytes == null) {
    check('screenshot captured', false, 'none');
    return;
  }
  final png = decodePng(Uint8List.fromList(bytes));
  final expected = capture.box.width.round();
  check(
    'screenshot width matches the element box',
    png.width == expected || png.width == (capture.box.width * dpr).round(),
    'png ${png.width}x${png.height}, box ${capture.box}',
  );
  final dominant = png.dominantColour();
  check(
    'the cropped screenshot is the element, not the page',
    dominant.key == colour && dominant.value > 0.8,
    '${dominant.key} covers ${(dominant.value * 100).toStringAsFixed(1)}%',
  );
}

/// Starts a pick, then clicks the element with synthetic CDP mouse input, so
/// the page's real listeners produce the selection.
Future<ElementCapture> _pickByClicking(
  BrowserService service,
  String locator, {
  bool isExpression = false,
}) async {
  final page = service.session!.page;
  final expression = isExpression
      ? locator
      : 'document.querySelector(${jsonEncode(locator)})';
  Future<(double, double)> centre() async {
    final point =
        await service.evaluate(
              '(function(){var r=($expression).getBoundingClientRect();'
              'return {x:r.left+r.width/2,y:r.top+r.height/2};})()',
            )
            as Map<Object?, Object?>;
    return ((point['x']! as num).toDouble(), (point['y']! as num).toDouble());
  }

  final pending = service.pickElement(timeout: const Duration(seconds: 20));
  unawaited(pending.then((_) {}, onError: (Object _) {}));
  // Let Runtime.addBinding and the injected script settle before clicking.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  // Read the position at click time, exactly as a user's cursor would.
  final (x, y) = await centre();
  await _dispatchClick(page, x, y);
  return pending;
}

Future<void> _dispatchClick(CdpPage page, double x, double y) async {
  await page.connection.send(
    'Input.dispatchMouseEvent',
    params: {
      'type': 'mouseMoved',
      'x': x,
      'y': y,
      'button': 'none',
      'buttons': 0,
    },
  );
  await page.connection.send(
    'Input.dispatchMouseEvent',
    params: {
      'type': 'mousePressed',
      'x': x,
      'y': y,
      'button': 'left',
      'buttons': 1,
      'clickCount': 1,
    },
  );
  await page.connection.send(
    'Input.dispatchMouseEvent',
    params: {
      'type': 'mouseReleased',
      'x': x,
      'y': y,
      'button': 'left',
      'buttons': 0,
      'clickCount': 1,
    },
  );
}

Future<void> _checkPickerRemoved(BrowserService service) async {
  final leftovers = await service.evaluate(
    "document.querySelectorAll('[data-karmashala-picker]').length",
  );
  final global = await service.evaluate('!!window.__karmashalaPicker');
  check('the highlight overlay was removed', leftovers == 0, '$leftovers left');
  check('the picker global was removed', global == false);
}

Future<bool> _failsWith(
  BrowserFailure expected,
  Future<Object?> Function() action,
) async {
  try {
    await action();
  } on BrowserException catch (e) {
    if (e.failure == expected) return true;
    stdout.writeln('      got ${e.failure.name}: ${e.message}');
    return false;
  } on Object catch (e) {
    stdout.writeln('      got $e');
    return false;
  }
  stdout.writeln('      no failure at all');
  return false;
}

String? _rgbToHex(String? rgb) {
  if (rgb == null) return null;
  final match = RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)').firstMatch(rgb);
  if (match == null) return rgb;
  final channels = [1, 2, 3]
      .map((g) => int.parse(match.group(g)!).toRadixString(16).padLeft(2, '0'))
      .join();
  return '#$channels';
}

/// An HTTP server that accepts the request and then never answers.
Future<HttpServer> _startHangingServer() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((request) {
    request.response.headers.contentType = ContentType.html;
    request.response.write('<html><body>loading');
    // Deliberately never closed.
  });
  return server;
}

Future<String> _writeTestPage() async {
  final directory = await Directory.systemTemp.createTemp('cdp-smoke-');
  final file = File(
    '${directory.path}${Platform.pathSeparator}'
    'cdp-smoke.html',
  );
  await file.writeAsString(_testPage);
  return Uri.file(file.path).toString();
}

const String _testPage =
    '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>CDP smoke</title>
<style>
  body { margin: 0; background: #ffffff; font-family: sans-serif; }
  .box { border: 0; }
  #red-box { width: 240px; height: 140px; background: $kRed;
             margin: 40px 0 0 60px; }
  #spacer { height: 2200px; }
  #blue-box { width: 300px; height: 180px; background: $kBlue;
              margin: 0 0 0 90px; }
</style>
</head>
<body>
  <div id="red-box" class="box"></div>
  <div id="shadow-host"></div>
  <div id="spacer"></div>
  <div id="blue-box" class="box"></div>
  <script>
    var host = document.getElementById('shadow-host');
    var root = host.attachShadow({ mode: 'open' });
    root.innerHTML =
      '<div id="shadow-inner" class="box" style="width:200px;height:100px;' +
      'background:$kGreen;margin:30px 0 0 60px"></div>';
  </script>
</body>
</html>
''';
