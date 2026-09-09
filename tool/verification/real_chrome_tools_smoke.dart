// Manual verification harness — NOT part of `flutter test`.
//
// Drives the *MCP tool handlers* against a real Chrome, through their real
// call path: `BrowserTools.call('browser_click', {...})`, exactly as the
// launcher control server invokes them. Unit fixtures cannot catch what this
// catches — a click that lands on the wrong element, key events a page ignores,
// a screenshot that is not of what it says.
//
//   dart run tool/verification/real_chrome_tools_smoke.dart
//
// Pass a URL to also measure what each tool costs on a real site, which is the
// only honest way to quote a token cost:
//
//   dart run tool/verification/real_chrome_tools_smoke.dart https://…
//
// It spawns its own Chrome on port 9334 with a throwaway profile, and kills the
// browser and deletes both temp directories at the end. Exit code 0 means every
// check passed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_browser/tools.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:karmashala/src/features/browser/application/browser_providers.dart';

import 'png_reader.dart';

const int kPort = 9334;
const String kAmber = '#f59e0b';

int _failures = 0;
final List<(String, int)> _costs = [];

void check(String label, bool ok, [String? detail]) {
  final mark = ok ? 'PASS' : 'FAIL';
  if (!ok) _failures++;
  stdout.writeln('  [$mark] $label${detail == null ? '' : ' — $detail'}');
}

Future<void> main(List<String> args) async {
  final pageFile = await _writeTestPage();
  final service = BrowserService(
    startProcess: browserProcessStarter(const LocalCommandRunner()),
  );
  final tools = BrowserTools(service);
  BrowserProcess? chrome;
  String? profileDir;

  try {
    stdout.writeln('\n== browser_navigate (connects on its own) ==');
    final connected = await tools.call('browser_navigate', {
      'url': pageFile,
      'port': kPort,
    });
    chrome = service.session!.endpoint.process;
    profileDir = service.session!.endpoint.userDataDir;
    check(
      'navigate reports where it ended up',
      _text(connected).contains('Browser tools smoke'),
      _firstLine(_text(connected)),
    );
    check(
      'it is one text block, not a JSON map',
      _blocks(connected).length == 1,
    );

    stdout.writeln('\n== browser_find ==');
    final signIn = await tools.call('browser_find', {'text': 'Sign in'});
    final findText = _text(signIn);
    _cost('browser_find(text: "Sign in")', findText);
    check(
      'finds exactly the button, not its wrapper',
      findText.contains('button#sign-in') && findText.contains('1 element'),
      _firstLine(findText),
    );
    check(
      'it reports the element as interactive',
      findText.contains('interactive'),
    );
    final boxes = await tools.call('browser_find', {'selector': '.box'});
    _cost('browser_find(selector: ".box")', _text(boxes));
    check(
      'a selector search counts every match',
      _text(boxes).contains('3 elements match'),
      _firstLine(_text(boxes)),
    );
    check(
      'a hidden element is left out and said to be left out',
      _text(
        await tools.call('browser_find', {'selector': '#hidden-box'}),
      ).contains('hidden'),
    );

    stdout.writeln('\n== browser_click ==');
    await service.evaluate('window.__log = []');
    final clicked = await tools.call('browser_click', {'text': 'Sign in'});
    _cost('browser_click(text: "Sign in")', _text(clicked));
    check(
      'the page\'s own click handler fired',
      await service.evaluate('(window.__log || []).join(",")') == 'sign-in',
      'log=${await service.evaluate('(window.__log || []).join(",")')}',
    );
    check(
      'the result names what was clicked',
      _text(clicked).contains('button#sign-in'),
      _firstLine(_text(clicked)),
    );

    await service.evaluate('window.__log = []');
    final farAway = await tools.call('browser_click', {
      'selector': '#far-below',
    });
    check(
      'an element 3000px below the fold is scrolled to and really clicked',
      await service.evaluate('(window.__log || []).join(",")') == 'far-below',
      _firstLine(_text(farAway)),
    );

    await service.evaluate('window.__log = []; window.scrollTo(0, 0)');
    final covered = await _refusal(tools, 'browser_click', {
      'selector': '#covered',
    });
    check(
      'a covered button is refused, with the blocker named',
      covered.contains('covering') && covered.contains('overlay'),
      covered.split('\n').first,
    );
    check(
      'and nothing was clicked',
      await service.evaluate('(window.__log || []).length') == 0,
    );

    final ambiguous = await _refusal(tools, 'browser_click', {
      'text': 'Duplicate',
    });
    check(
      'an ambiguous text query is refused and the matches listed',
      ambiguous.contains('matches 2 elements') && ambiguous.contains('[1]'),
      ambiguous.split('\n').first,
    );
    await service.evaluate('window.__log = []');
    final byIndex = await tools.call('browser_click', {
      'text': 'Duplicate',
      'index': 1,
    });
    check(
      'index picks the second one',
      await service.evaluate('(window.__log || []).join(",")') == 'dup-2',
      _firstLine(_text(byIndex)),
    );

    final missing = await _refusal(tools, 'browser_click', {
      'text': 'Not on this page',
    });
    check(
      'a query that matches nothing says so, and says what it was',
      missing.contains('Nothing matches') &&
          missing.contains('Not on this page'),
      missing,
    );

    stdout.writeln('\n== browser_type (real key events) ==');
    await service.evaluate('window.__keys = 0; window.__searchInput = 0');
    final typed = await tools.call('browser_type', {
      'selector': '#search',
      'value': 'hello',
    });
    _cost('browser_type', _text(typed));
    check(
      'the page saw one keydown per character — not a bulk insert',
      await service.evaluate('window.__keys') == 5,
      'keydown count = ${await service.evaluate('window.__keys')}',
    );
    check(
      'the field holds the text',
      await service.evaluate('document.getElementById("search").value') ==
          'hello',
    );
    check(
      'the result says the value was verified',
      _text(typed).contains('holds exactly that'),
      _firstLine(_text(typed)),
    );

    stdout.writeln('\n== browser_fill ==');
    final filled = await tools.call('browser_fill', {
      'text': 'Email address',
      'value': 'ada@example.com',
    });
    _cost('browser_fill', _text(filled));
    check(
      'a field found by its placeholder is filled',
      await service.evaluate('document.getElementById("email").value') ==
          'ada@example.com',
    );
    check(
      'the read-back is reported',
      _text(filled).contains('holds exactly that'),
      _firstLine(_text(filled)),
    );
    await tools.call('browser_fill', {
      'selector': '#email',
      'value': 'grace@example.com',
    });
    check(
      'filling again replaces rather than appends',
      await service.evaluate('document.getElementById("email").value') ==
          'grace@example.com',
    );
    final capped = await tools.call('browser_fill', {
      'selector': '#short',
      'value': 'far too long for this field',
    });
    check(
      'a maxlength that eats the value is reported, not claimed as success',
      _text(capped).contains('NOT what was sent'),
      _firstLine(_text(capped)),
    );
    final select = await tools.call('browser_fill', {
      'selector': '#colour',
      'value': 'Green',
    });
    check(
      'a <select> is set by its visible label and fires change',
      await service.evaluate('document.getElementById("colour").value') ==
              'g' &&
          await service.evaluate('window.__colourChanges') == 1,
      _firstLine(_text(select)),
    );
    final notAField = await _refusal(tools, 'browser_fill', {
      'selector': '#sign-in',
      'value': 'x',
    });
    check(
      'filling something that is not a field explains why not',
      notAField.contains('not a text field'),
      notAField,
    );

    stdout.writeln('\n== browser_key ==');
    await service.evaluate('document.getElementById("email").focus()');
    await tools.call('browser_key', {'key': 'tab'});
    check(
      'Tab moves focus the way it does for a person',
      await service.evaluate('document.activeElement.id') == 'short',
      'focus is now ${await service.evaluate('document.activeElement.id')}',
    );
    await service.evaluate('window.__submits = 0; window.__enter = 0');
    await tools.call('browser_fill', {
      'selector': '#search',
      'value': 'query',
      'submit': true,
    });
    check(
      'submit presses Enter, and the page sees a real Enter keydown',
      await service.evaluate('window.__enter') == 1,
      'enter keydowns = ${await service.evaluate('window.__enter')}',
    );
    check(
      'the form submits, as it would for a person pressing Enter',
      await service.evaluate('window.__submits') == 1,
      'submits = ${await service.evaluate('window.__submits')}',
    );

    stdout.writeln('\n== browser_screenshot ==');
    final shot = await tools.call('browser_screenshot', {
      'selector': '#amber-box',
    });
    final shotBlocks = _blocks(shot);
    check(
      'a screenshot comes back as an image block, not base64 in JSON',
      shotBlocks.first['type'] == 'image' &&
          shotBlocks.first['mimeType'] == 'image/png',
    );
    final png = decodePng(
      Uint8List.fromList(base64Decode(shotBlocks.first['data']! as String)),
    );
    final dominant = png.dominantColour();
    check(
      'the clipped image really is that element',
      dominant.key == kAmber && dominant.value > 0.8,
      '${dominant.key} covers ${(dominant.value * 100).toStringAsFixed(1)}%',
    );
    _cost('browser_screenshot (text part only)', _text(shot));

    stdout.writeln('\n== browser_capture ==');
    final capture = await tools.call('browser_capture', {'text': 'Sign in'});
    final captureText = _text(capture);
    _cost('browser_capture(text: "Sign in")', captureText);
    check(
      'the bundle is the element that was asked for',
      captureText.contains('id="sign-in"') && captureText.contains('#sign-in'),
      _firstLine(captureText),
    );
    check(
      'it carries the curated styles, not all ~480 properties',
      captureText.contains('background-color:') &&
          !captureText.contains('-webkit-'),
    );
    check(
      'and a cropped screenshot as an image block',
      _blocks(capture).first['type'] == 'image',
    );
    final full = await tools.call('browser_capture', {
      'selector': '#sign-in',
      'full': true,
      'image': false,
    });
    _cost('browser_capture(full: true)', _text(full));
    check(
      'full=true opts into every computed property',
      _text(full).contains('Every computed property') &&
          _text(full).contains('-webkit-'),
    );

    stdout.writeln('\n== browser_pick (synthetic click, as a hand would) ==');
    final picked = await _pickByClicking(tools, service, '#amber-box');
    final pickedText = _text(picked);
    _cost('browser_pick', pickedText);
    check(
      'the captured bundle is the element that was clicked',
      pickedText.contains('#amber-box') &&
          pickedText.contains('id="amber-box"'),
      _firstLine(pickedText),
    );
    check(
      'its computed colour is the element\'s own',
      pickedText.contains('background-color: rgb(245, 158, 11)'),
    );
    final pickedPng = decodePng(
      Uint8List.fromList(
        base64Decode(_blocks(picked).first['data']! as String),
      ),
    );
    final pickedDominant = pickedPng.dominantColour();
    check(
      'the cropped screenshot shows the element, with no highlight baked in',
      pickedDominant.key == kAmber && pickedDominant.value > 0.8,
      '${pickedDominant.key} covers '
          '${(pickedDominant.value * 100).toStringAsFixed(1)}%',
    );

    stdout.writeln('\n== browser_tabs ==');
    final tabs = await tools.call('browser_tabs', const {});
    _cost('browser_tabs', _text(tabs));
    check(
      'the tab being driven is marked',
      _text(tabs).contains('* ') && _text(tabs).contains('Browser tools smoke'),
      _firstLine(_text(tabs)),
    );
    final opened = await tools.call('browser_tabs', {'open': 'about:blank'});
    check('a tab can be opened', _text(opened).contains('Opened a tab'));
    final tabsAfter = _text(await tools.call('browser_tabs', const {}));
    check(
      'the new tab is listed',
      tabsAfter.contains('2 drivable tabs'),
      _firstLine(tabsAfter),
    );
    final newId = RegExp(
      r'^\s{2}(\S+)\s',
      multiLine: true,
    ).allMatches(tabsAfter).map((m) => m.group(1)!).firstOrNull;
    if (newId != null) {
      final switched = await tools.call('browser_tabs', {'select': newId});
      check(
        'switching drives the other tab',
        _text(switched).contains('about:blank'),
        _firstLine(_text(switched)),
      );
      await tools.call('browser_navigate', {'url': pageFile});
    }

    stdout.writeln('\n== failures are surfaced, not flattened ==');
    check(
      'a bad selector says which selector',
      (await _refusal(tools, 'browser_find', {
        'selector': '<<<',
      })).contains('invalid selector'),
    );
    check(
      'a throwing expression reports the JavaScript error',
      (await _refusal(tools, 'browser_evaluate', {
        'expression': 'throw new Error("boom")',
      })).contains('boom'),
    );
    check(
      'an unknown key lists the valid ones',
      (await _refusal(tools, 'browser_key', {
        'key': 'f13',
      })).contains('arrowDown'),
    );
    await service.disconnect();
    check(
      'a verb with no session says how to get one',
      (await _refusal(tools, 'browser_click', {
        'selector': '#sign-in',
      })).contains('browser_connect'),
    );

    if (args.isNotEmpty) await _realPageCosts(tools, service, args.first);

    stdout.writeln('\n== token cost ==');
    final schemaChars = jsonEncode(browserToolSchemas).length;
    _costs.add(('tools/list (all 12 schemas)', schemaChars));
    for (final (label, chars) in _costs) {
      stdout.writeln(
        '  ${label.padRight(38)} ${chars.toString().padLeft(6)} chars '
        '(~${(chars / 4).round()} tokens)',
      );
    }
  } finally {
    await service.disconnect();
    await chrome?.kill();
    await _remove(profileDir);
    await _remove(File.fromUri(Uri.parse(pageFile)).parent.path);
  }

  stdout.writeln(
    _failures == 0 ? '\nAll checks passed.' : '\n$_failures check(s) FAILED.',
  );
  exit(_failures == 0 ? 0 : 1);
}

/// Measures what the tools cost on a page nobody wrote for a test.
///
/// A fixture page flatters every listing tool: it has twenty elements and no
/// framework. The numbers worth quoting come from a site with real markup.
Future<void> _realPageCosts(
  BrowserTools tools,
  BrowserService service,
  String url,
) async {
  stdout.writeln('\n== real page: $url ==');
  await tools.call('browser_navigate', {'url': url});
  final links = await tools.call('browser_find', {'selector': 'a'});
  _cost('real: browser_find(selector: "a")', _text(links));
  final elementCount = await service.evaluate(
    'document.querySelectorAll("*").length',
  );
  stdout.writeln('  the page has $elementCount elements');
  final first = await service.evaluate(
    'document.querySelector("a") ? true : false',
  );
  if (first == true) {
    final capture = await tools.call('browser_capture', {
      'selector': 'a',
      'image': false,
    });
    _cost('real: browser_capture(selector: "a")', _text(capture));
    final full = await tools.call('browser_capture', {
      'selector': 'a',
      'full': true,
      'image': false,
    });
    _cost('real: browser_capture(full: true)', _text(full));
  }
  final body = await tools.call('browser_capture', {
    'selector': 'body',
    'image': false,
  });
  _cost('real: browser_capture(selector: "body")', _text(body));
  final shot = await tools.call('browser_screenshot', const {});
  _cost('real: browser_screenshot (text part)', _text(shot));
  stdout.writeln(
    '  viewport screenshot: '
    '${(base64Decode(_blocks(shot).first['data']! as String).length / 1024).toStringAsFixed(0)} KB PNG',
  );
}

/// Runs a pick and clicks the element for the user, reading the point at click
/// time (a rect read before a scroll settles names a place the element has
/// already left).
Future<Object?> _pickByClicking(
  BrowserTools tools,
  BrowserService service,
  String selector,
) async {
  final page = service.session!.page;
  final pending = tools.call('browser_pick', {'timeoutSeconds': 20});
  unawaited(pending.then((_) {}, onError: (Object _) {}));
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final point =
      await service.evaluate(
            '(function(){var r=document.querySelector("$selector")'
            '.getBoundingClientRect();'
            'return {x:r.left+r.width/2,y:r.top+r.height/2};})()',
          )
          as Map<Object?, Object?>;
  await _dispatchClick(
    page,
    (point['x']! as num).toDouble(),
    (point['y']! as num).toDouble(),
  );
  return pending;
}

Future<void> _dispatchClick(CdpPage page, double x, double y) async {
  for (final event in [
    {'type': 'mouseMoved', 'button': 'none', 'buttons': 0},
    {'type': 'mousePressed', 'button': 'left', 'buttons': 1, 'clickCount': 1},
    {'type': 'mouseReleased', 'button': 'left', 'buttons': 0, 'clickCount': 1},
  ]) {
    await page.connection.send(
      'Input.dispatchMouseEvent',
      params: {...event, 'x': x, 'y': y},
    );
  }
}

/// The message a tool call refuses with. A tool that *succeeds* here is itself
/// a failure, so that is reported rather than throwing.
Future<String> _refusal(
  BrowserTools tools,
  String tool,
  Map<String, dynamic> args,
) async {
  try {
    final result = await tools.call(tool, args);
    _failures++;
    return 'NO FAILURE AT ALL: ${_text(result)}';
  } on Object catch (error) {
    return '$error';
  }
}

List<Map<String, Object?>> _blocks(Object? result) => [
  for (final block in ((result! as Map)['_mcpContent']! as List))
    (block as Map).cast<String, Object?>(),
];

String _text(Object? result) => [
  for (final block in _blocks(result))
    if (block['type'] == 'text') block['text'] as String,
].join('\n');

String _firstLine(String text) => text.split('\n').first;

void _cost(String label, String text) => _costs.add((label, text.length));

/// Deletes a temp directory, retrying: Chrome keeps handles open for a moment
/// after it exits, and a profile left in %TEMP% is exactly the mess this
/// harness is supposed to avoid.
Future<void> _remove(String? path) async {
  if (path == null) return;
  final directory = Directory(path);
  for (var attempt = 0; attempt < 10; attempt++) {
    if (!directory.existsSync()) return;
    try {
      directory.deleteSync(recursive: true);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  stdout.writeln('  NOTE: could not delete $path; delete it by hand.');
}

Future<String> _writeTestPage() async {
  final directory = await Directory.systemTemp.createTemp('cdp-tools-');
  final file = File('${directory.path}${Platform.pathSeparator}cdp-tools.html');
  await file.writeAsString(_testPage);
  return Uri.file(file.path).toString();
}

const String _testPage =
    '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Browser tools smoke</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #ffffff; }
  .box { width: 200px; height: 120px; }
  #amber-box { background: $kAmber; }
  #hidden-box { display: none; }
  #covered-wrap { position: relative; display: inline-block; }
  #overlay { position: absolute; inset: -4px; background: rgba(0,0,0,0.4);
             z-index: 99; }
  #spacer { height: 3000px; }
</style>
</head>
<body>
  <h1>Browser tools smoke</h1>
  <button id="sign-in">Sign in</button>
  <button id="dup-1">Duplicate</button>
  <button id="dup-2">Duplicate</button>
  <span id="covered-wrap">
    <button id="covered">Covered button</button>
    <div id="overlay"></div>
  </span>
  <form id="form">
    <input id="search" placeholder="Search">
    <input id="email" placeholder="Email address">
    <input id="short" maxlength="4">
    <select id="colour">
      <option value="r">Red</option>
      <option value="g">Green</option>
    </select>
    <button id="go" type="submit">Go</button>
  </form>
  <div id="amber-box" class="box"></div>
  <div id="hidden-box" class="box"></div>
  <div id="third-box" class="box" style="background:#ddd"></div>
  <div id="spacer"></div>
  <button id="far-below">Far below</button>
  <script>
    window.__log = [];
    window.__keys = 0;
    window.__submits = 0;
    window.__colourChanges = 0;
    window.__enter = 0;
    document.addEventListener('click', function (e) {
      if (e.target && e.target.id) window.__log.push(e.target.id);
    });
    document.getElementById('search')
      .addEventListener('keydown', function (e) {
        window.__keys++;
        if (e.key === 'Enter') window.__enter++;
      });
    document.getElementById('colour')
      .addEventListener('change', function () { window.__colourChanges++; });
    document.getElementById('form')
      .addEventListener('submit', function (e) {
        e.preventDefault();
        window.__submits++;
      });
  </script>
</body>
</html>
''';
