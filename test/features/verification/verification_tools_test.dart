import 'package:karmashala/src/features/mcp/mcp_tool_dispatcher.dart';
import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala/src/features/verification/application/verification_tool_schemas.dart';
import 'package:karmashala/src/features/verification/application/verification_tools.dart';
import 'package:karmashala/src/features/verification/domain/verdict_attribution.dart';
import 'package:flutter_test/flutter_test.dart';

import 'verification_harness.dart';

/// The blocks of an `_mcpContent` result.
List<Map<String, Object?>> blocks(Object? result) => [
  for (final block in (result! as Map)['_mcpContent']! as List)
    Map<String, Object?>.from(block as Map),
];

/// The text of the one text block.
String textOf(Object? result) =>
    blocks(result).firstWhere((b) => b['type'] == 'text')['text']! as String;

int imagesIn(Object? result) =>
    blocks(result).where((b) => b['type'] == 'image').length;

void main() {
  late VerificationHarness h;
  late VerificationTools tools;

  setUp(() {
    h = VerificationHarness();
    tools = VerificationTools(h.service);
  });
  tearDown(() => h.dispose());

  group('the tool set', () {
    test('claims exactly the verification_ namespace', () {
      expect(VerificationTools.handles('verification_start'), isTrue);
      expect(VerificationTools.handles('browser_click'), isFalse);
      expect(VerificationTools.handles('device_tap'), isFalse);
    });

    test('every schema is served by the control server', () {
      final served = McpToolDispatcher.toolSchemas
          .map((s) => s['name'])
          .toSet();
      for (final schema in verificationToolSchemas) {
        expect(served, contains(schema['name']));
      }
      expect(verificationToolSchemas, hasLength(5));
    });

    test('an unknown tool in the namespace is named, not swallowed', () {
      expect(
        () => tools.call('verification_teleport', const {}),
        throwsA(isA<VerificationException>()),
      );
    });
  });

  group('verification_start', () {
    test('a URL starts a browser run and says what is now recorded', () async {
      final result = await tools.call('verification_start', {
        'url': 'https://example.com',
        'title': 'the save button saves',
      });

      final text = textOf(result);
      expect(text, contains('Recording run-001'));
      expect(text, contains('the save button saves'));
      expect(text, contains('browser_*'));
      expect(h.service.activeRun, isNotNull);
    });

    test('a serial starts a device run', () async {
      final text = textOf(
        await tools.call('verification_start', {
          'serial': 'FAKE123',
          'package': 'com.example.app',
        }),
      );
      expect(text, contains('device_*'));
      expect(text, contains('com.example.app'));
    });

    test('neither url nor serial is refused with the way forward', () async {
      await expectLater(
        tools.call('verification_start', const {}),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('list_devices'),
          ),
        ),
      );
    });

    test('both url and serial is refused rather than guessed', () async {
      await expectLater(
        tools.call('verification_start', {
          'url': 'https://example.com',
          'serial': 'FAKE123',
        }),
        throwsA(isA<VerificationException>()),
      );
    });
  });

  group('verification_note and finish', () {
    test('a note needs something to say', () async {
      await tools.call('verification_start', {'url': 'https://example.com'});
      await expectLater(
        tools.call('verification_note', const {'text': '   '}),
        throwsA(isA<VerificationException>()),
      );
    });

    test('an unknown verdict lists the ones that exist', () async {
      await tools.call('verification_start', {'url': 'https://example.com'});
      await expectLater(
        tools.call('verification_finish', const {'verdict': 'maybe'}),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('inconclusive'),
          ),
        ),
      );
    });

    test(
      'finishing reports the verdict, the counts and where to look',
      () async {
        await tools.call('verification_start', {
          'url': 'https://example.com',
          'title': 'the save button saves',
        });
        await tools.call('verification_note', const {'text': 'clicked save'});
        final text = textOf(
          await tools.call('verification_finish', const {
            'verdict': 'pass',
            'reason': 'the row appeared',
          }),
        );

        expect(text, startsWith('PASS — the save button saves'));
        expect(text, contains('the row appeared'));
        expect(text, contains('report.md'));
        expect(text, contains('steps'));
      },
    );
  });

  group('verification_list', () {
    test('says so when there is nothing, with the way to start one', () async {
      final text = textOf(await tools.call('verification_list', const {}));
      expect(text, contains('verification_start'));
    });

    test('one line per run, newest first, and no JSON', () async {
      await tools.call('verification_start', {'url': 'https://a.test'});
      await tools.call('verification_finish', const {'verdict': 'pass'});
      await tools.call('verification_start', {'url': 'https://b.test'});
      await tools.call('verification_finish', const {'verdict': 'fail'});

      final result = await tools.call('verification_list', const {});
      final text = textOf(result);
      expect(blocks(result), hasLength(1));
      expect(text, isNot(contains('{')));
      expect(
        text.indexOf('https://b.test'),
        lessThan(text.indexOf('https://a.test')),
      );
      expect(text, contains('FAIL'));
      expect(text, contains('pass'));
      // A listing that says "0 steps" for a run with steps is worse than none.
      expect(text, isNot(contains('0 steps')));
    });
  });

  group('verification_get', () {
    Future<String> finishedRun() async {
      await tools.call('verification_start', {
        'url': 'https://example.com',
        'title': 'a run with evidence',
      });
      await h.browser.service.screenshot();
      h.browser.socket.emitEvent('Runtime.consoleAPICalled', {
        'type': 'error',
        'args': [
          {'type': 'string', 'value': 'TypeError: save is not a function'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      await tools.call('verification_finish', const {
        'verdict': 'fail',
        'reason': 'save throws',
      });
      return h.service.list().first.id;
    }

    test('is compact by default: no images, no file contents', () async {
      final id = await finishedRun();
      final result = await tools.call('verification_get', {'id': id});

      expect(imagesIn(result), 0);
      final text = textOf(result);
      expect(text, contains('FAIL — a run with evidence'));
      expect(text, contains('Steps ('));
      expect(text, contains('Captured ('));
      expect(text, isNot(contains('TypeError: save is not a function')));
      // And it tells the caller what it is holding back, and how to get it.
      expect(text, contains('images:true'));
      expect(text, contains('full:true'));
    });

    test(
      'images:true attaches them as image blocks, not base64 text',
      () async {
        final id = await finishedRun();
        final result = await tools.call('verification_get', {
          'id': id,
          'images': true,
        });

        expect(imagesIn(result), greaterThan(0));
        expect(blocks(result).first['mimeType'], 'image/png');
        expect(textOf(result), isNot(contains('iVBOR')));
      },
    );

    test('full:true brings the evidence text with it', () async {
      final id = await finishedRun();
      final text = textOf(
        await tools.call('verification_get', {'id': id, 'full': true}),
      );
      expect(text, contains('TypeError: save is not a function'));
    });

    test('a prefix works, and an ambiguous one lists the candidates', () async {
      await finishedRun();
      await finishedRun();

      expect(
        textOf(await tools.call('verification_get', const {'id': 'run-001'})),
        contains('a run with evidence'),
      );
      await expectLater(
        tools.call('verification_get', const {'id': 'run-'}),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('matches 2 runs'),
          ),
        ),
      );
    });

    test('an id nobody has says so plainly', () async {
      await expectLater(
        tools.call('verification_get', const {'id': 'nope'}),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('No verification run'),
          ),
        ),
      );
    });

    test('with no id and nothing recording, it says which to pass', () async {
      await expectLater(
        tools.call('verification_get', const {}),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('verification_list'),
          ),
        ),
      );
    });

    test('with no id it reads the run that is recording now', () async {
      await tools.call('verification_start', {
        'url': 'https://example.com',
        'title': 'in progress',
      });
      final text = textOf(await tools.call('verification_get', const {}));
      expect(text, contains('STILL RECORDING'));
      expect(text, contains('in progress'));
    });
  });

  group('the caller is recorded as the producer of the verdict', () {
    // The bridge sends `callerSessionId` from KARMASHALA_SESSION_ID; the
    // control server hands it to this tool set. Without it, every verdict is
    // a self-graded exam that does not admit to being one.
    late VerificationTools called;
    setUp(() => called = VerificationTools(h.service, callerSessionId: 's-1'));

    test('a run started over MCP knows who started it', () async {
      await called.call('verification_start', {'url': 'https://example.com'});
      final run = h.service.activeRun!;
      expect(run.producedBySessionId, 's-1');
      // With no explicit subject the caller is also the work under test, and
      // the run says out loud that it graded itself.
      expect(run.sessionId, 's-1');
      expect(run.attribution, VerdictAttribution.author);
    });

    test('verifying another session names both sides', () async {
      await called.call('verification_start', {
        'url': 'https://example.com',
        'sessionId': 's-2',
      });
      final run = h.service.activeRun!;
      expect(run.sessionId, 's-2');
      expect(run.producedBySessionId, 's-1');
      expect(run.attribution, VerdictAttribution.independent);
    });

    test('finishing attributes the session that signed off', () async {
      await called.call('verification_start', {
        'url': 'https://example.com',
        'sessionId': 's-2',
      });
      final result = await VerificationTools(
        h.service,
        callerSessionId: 's-3',
      ).call('verification_finish', {'verdict': 'pass'});

      expect(h.service.list().single.producedBySessionId, 's-3');
      expect(textOf(result), contains('by another session'));
    });

    test('a pass the session gave itself says it is self-verified, and how '
        'to get an independent one', () async {
      await called.call('verification_start', {'url': 'https://example.com'});
      final result = await called.call('verification_finish', {
        'verdict': 'pass',
      });
      expect(textOf(result), contains('SELF-VERIFIED'));
      expect(textOf(result), contains('checks_run'));
    });

    test('an independent pass carries no such warning', () async {
      await called.call('verification_start', {
        'url': 'https://example.com',
        'sessionId': 's-2',
      });
      final result = await called.call('verification_finish', {
        'verdict': 'pass',
      });
      expect(textOf(result), isNot(contains('SELF-VERIFIED')));
    });

    test('a caller outside a session leaves the run unattributed', () async {
      await tools.call('verification_start', {'url': 'https://example.com'});
      await tools.call('verification_finish', {'verdict': 'pass'});

      final run = h.service.list().single;
      expect(run.producedBySessionId, isNull);
      expect(run.attribution, VerdictAttribution.notRecorded);
    });

    test('the list column says which runs graded themselves', () async {
      await called.call('verification_start', {'url': 'https://example.com'});
      await called.call('verification_finish', {'verdict': 'pass'});

      final text = textOf(await called.call('verification_list', const {}));
      expect(text, contains('verifier'));
      expect(text, contains('self'));
    });
  });
}
