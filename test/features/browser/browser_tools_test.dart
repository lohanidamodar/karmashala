import 'dart:convert';

import 'package:karmashala/src/features/browser/application/browser_tool_schemas.dart';
import 'package:karmashala/src/features/browser/application/browser_tools.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_browser.dart';

List<Map<String, Object?>> blocks(Object? result) => [
  for (final block in ((result! as Map)['_mcpContent']! as List))
    (block as Map).cast<String, Object?>(),
];

String textOf(Object? result) => [
  for (final block in blocks(result))
    if (block['type'] == 'text') block['text'] as String,
].join('\n');

Future<(BrowserTools, FakeBrowser)> connectedTools({
  Object? Function(PageScript kind, String expression)? replies,
  bool connect = true,
}) async {
  final fake = FakeBrowser();
  fake.onEvaluate = (expression) {
    final kind = scriptKind(expression);
    if (kind != null) return replies?.call(kind, expression);
    if (expression == 'location.href') return 'https://example.com/app';
    if (expression == 'document.title') return 'Example';
    return null;
  };
  if (connect) await fake.connect();
  return (BrowserTools(fake.service), fake);
}

void main() {
  group('the tool set', () {
    test('every schema is well formed', () {
      for (final schema in browserToolSchemas) {
        expect(schema['name'], isA<String>());
        expect((schema['name']! as String).startsWith('browser_'), isTrue);
        expect(schema['description'], isA<String>());
        expect(
          (schema['description']! as String).length,
          greaterThan(40),
          reason: '${schema['name']} needs a description worth reading',
        );
        final input = schema['inputSchema']! as Map<String, dynamic>;
        expect(input['type'], 'object');
        expect(input['properties'], isA<Map<String, dynamic>>());
        for (final required in (input['required'] as List? ?? const [])) {
          expect(
            (input['properties']! as Map).containsKey(required),
            isTrue,
            reason: '${schema['name']} requires an undeclared "$required"',
          );
        }
      }
    });

    test('names are unique and handled', () {
      final names = [for (final s in browserToolSchemas) s['name']! as String];
      expect(names.toSet(), hasLength(names.length));
      for (final name in names) {
        expect(BrowserTools.handles(name), isTrue);
      }
      expect(BrowserTools.handles('list_devices'), isFalse);
    });

    test('the control server serves them alongside its own', () {
      final names = [
        for (final s in LauncherControlServer.toolSchemas) s['name'],
      ];
      expect(names, containsAll(['list_sessions', 'browser_click']));
      expect(names.toSet(), hasLength(names.length));
    });

    test('an unknown browser tool is named in the error', () async {
      final (tools, _) = await connectedTools();
      await expectLater(
        tools.call('browser_nope', const {}),
        throwsA(
          isA<BrowserToolException>().having(
            (e) => e.message,
            'message',
            contains('browser_nope'),
          ),
        ),
      );
    });
  });

  group('results are compact', () {
    test('a listing is one text block, not a JSON map', () async {
      final (tools, _) = await connectedTools(
        replies: (kind, _) => kind == PageScript.find
            ? findReply([describedElement(), describedElement(selector: '#b')])
            : null,
      );
      final result = await tools.call('browser_find', {'selector': 'button'});
      expect(blocks(result), hasLength(1));
      expect(blocks(result).single['type'], 'text');
      final text = textOf(result);
      expect(text, contains('2 elements match selector `button`'));
      expect(text, contains('[0] button#go'));
      expect(text, isNot(contains('{')), reason: 'no JSON in a listing');
    });

    test('a search that matches nothing says so in one line', () async {
      final (tools, _) = await connectedTools(
        replies: (kind, _) =>
            kind == PageScript.find ? findReply(const [], hidden: 2) : null,
      );
      final text = textOf(
        await tools.call('browser_find', {'text': 'Missing'}),
      );
      expect(text, contains('Nothing matches text "Missing"'));
      expect(text, contains('includeHidden'));
    });

    test('a screenshot is an image block, never base64 in text', () async {
      final (tools, _) = await connectedTools();
      final result = await tools.call('browser_screenshot', const {});
      expect(blocks(result).first['type'], 'image');
      expect(blocks(result).first['mimeType'], 'image/png');
      expect(base64Decode(blocks(result).first['data']! as String), isNotEmpty);
      expect(textOf(result), isNot(contains('data')));
      expect(textOf(result), contains('KB PNG'));
    });

    test(
      'a capture defaults to the curated styles and adds the crop',
      () async {
        final (tools, _) = await connectedTools(
          replies: (kind, _) => kind == PageScript.describeSelector
              ? describeSelectorReply()
              : null,
        );
        final result = await tools.call('browser_capture', {'selector': '#go'});
        expect(blocks(result).first['type'], 'image');
        final text = textOf(result);
        expect(text, contains('```html'));
        expect(text, contains('background-color: rgb(1, 2, 3);'));
        expect(text, isNot(contains('Every computed property')));
      },
    );

    test(
      'full=true opts into every property, image=false drops the crop',
      () async {
        final (tools, _) = await connectedTools(
          replies: (kind, _) => kind == PageScript.describeSelector
              ? describeSelectorReply()
              : null,
        );
        final result = await tools.call('browser_capture', {
          'selector': '#go',
          'full': true,
          'image': false,
        });
        expect(blocks(result).every((b) => b['type'] == 'text'), isTrue);
        expect(textOf(result), contains('Every computed property (2)'));
      },
    );

    test('a picked element is introduced as the user\'s choice', () async {
      final (tools, fake) = await connectedTools();
      fake.onEvaluate = (expression) {
        if (expression.contains('__karmashalaPicker')) return true;
        return null;
      };
      final pending = tools.call('browser_pick', {'timeoutSeconds': 5});
      await Future<void>.delayed(Duration.zero);
      fake.socket.emitEvent('Runtime.bindingCalled', {
        'name': '__karmashalaPick',
        'payload': jsonEncode({
          'ok': true,
          'selector': '#go',
          'tagName': 'button',
          'box': {'x': 1, 'y': 2, 'width': 3, 'height': 4},
          'url': 'https://example.com',
          'title': 'Example',
        }),
      });
      final text = textOf(await pending);
      expect(text, startsWith('The user pointed at this element'));
      expect(text, contains('`#go`'));
    });
  });

  group('driving', () {
    Object? standard(PageScript kind, String expression) => switch (kind) {
      PageScript.find => findReply([describedElement()]),
      PageScript.clickTarget => clickReply(),
      PageScript.prepareField => {
        'ok': true,
        'mode': 'text',
        'element': describedElement(tagName: 'input'),
        'had': '',
      },
      PageScript.readField => 'typed',
      _ => null,
    };

    test('a click says what it hit and where', () async {
      final (tools, _) = await connectedTools(replies: standard);
      final text = textOf(await tools.call('browser_click', {'text': 'Go'}));
      expect(text, contains('Clicked button#go'));
      expect(text, contains('(60, 35)'));
      expect(text, contains('Look again'));
    });

    test('typing reports the read-back value', () async {
      final (tools, _) = await connectedTools(replies: standard);
      final text = textOf(
        await tools.call('browser_type', {'selector': '#go', 'value': 'typed'}),
      );
      expect(text, contains('Typed "typed"'));
      expect(text, contains('holds exactly that'));
    });

    test(
      'a value the page did not keep is called out, not glossed over',
      () async {
        final (tools, _) = await connectedTools(
          replies: (kind, e) =>
              kind == PageScript.readField ? 'ty' : standard(kind, e),
        );
        final text = textOf(
          await tools.call('browser_fill', {
            'selector': '#go',
            'value': 'typed',
          }),
        );
        expect(text, contains('NOT what was sent'));
        expect(text, contains('"ty"'));
      },
    );

    test('an unknown key is refused before anything is dispatched', () async {
      final (tools, fake) = await connectedTools();
      await expectLater(
        tools.call('browser_key', {'key': 'f13'}),
        throwsA(isA<BrowserToolException>()),
      );
      expect(fake.framesFor('Input.dispatchKeyEvent'), isEmpty);
    });

    test('a missing required argument is named', () async {
      final (tools, _) = await connectedTools();
      await expectLater(
        tools.call('browser_navigate', const {}),
        throwsA(
          isA<BrowserToolException>().having(
            (e) => e.message,
            'message',
            'url is required.',
          ),
        ),
      );
    });
  });

  group('connecting', () {
    test('navigate connects on its own and reports the mode', () async {
      final (tools, fake) = await connectedTools(connect: false);
      final text = textOf(
        await tools.call('browser_navigate', {'url': 'https://example.com'}),
      );
      expect(text, contains('Attached to the browser already listening'));
      expect(text, contains('https://example.com/app'));
      expect(fake.service.isConnected, isTrue);
    });

    test('connect says which browser and points at the pane', () async {
      final (tools, _) = await connectedTools(connect: false);
      final text = textOf(await tools.call('browser_connect', const {}));
      expect(text, contains('port 9222'));
      expect(text, contains('browser pane'));
    });

    test('tabs list the pages and mark the one being driven', () async {
      final fake = FakeBrowser(
        targets: [
          fakeTarget('A', url: 'https://a.test', title: 'A'),
          fakeTarget('B', url: 'https://b.test', title: 'B'),
        ],
      );
      await fake.connect();
      final text = textOf(
        await BrowserTools(fake.service).call('browser_tabs', const {}),
      );
      expect(text, contains('2 drivable tabs'));
      expect(text, contains('* A'));
      expect(text, contains('  B'));
    });

    test('opening a tab does not silently switch to it', () async {
      final fake = FakeBrowser();
      await fake.connect();
      final text = textOf(
        await BrowserTools(
          fake.service,
        ).call('browser_tabs', {'open': 'https://new.test'}),
      );
      expect(fake.endpoint.openedUrl, 'https://new.test');
      expect(text, contains('still driving its current page'));
      expect(fake.service.session!.page.target.id, 'PAGE-1');
    });
  });

  group('failures', () {
    test('a browser failure keeps its own actionable wording', () async {
      final (tools, _) = await connectedTools(
        replies: (kind, _) => kind == PageScript.find
            ? {'error': 'invalid selector: bad token'}
            : null,
      );
      await expectLater(
        tools.call('browser_find', {'selector': '<<<'}),
        throwsA(
          isA<BrowserToolException>().having(
            (e) => '$e',
            'rendered',
            allOf(
              contains('No element in the page matched'),
              contains('bad token'),
              isNot(contains('Exception')),
            ),
          ),
        ),
      );
    });

    test('a verb with no session is told how to get one', () async {
      final (tools, _) = await connectedTools(connect: false);
      await expectLater(
        tools.call('browser_click', {'selector': '#go'}),
        throwsA(
          isA<BrowserToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Not connected'), contains('browser_connect')),
          ),
        ),
      );
    });
  });
}
