import 'dart:convert';

import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

import 'fake_cdp_socket.dart';

const _target = BrowserTarget(
  id: 'T1',
  type: 'page',
  title: 'Example',
  url: 'https://example.com',
  webSocketDebuggerUrl: 'ws://127.0.0.1:9222/devtools/page/T1',
);

/// The payload the injected script sends when the user clicks an element.
String clickPayload({String? selector = '#go'}) => jsonEncode({
  'ok': true,
  'selector': selector,
  'tagName': 'button',
  'id': 'go',
  'classNames': ['primary'],
  'clientX': 100,
  'clientY': 200,
  'box': {'x': 10, 'y': 20, 'width': 120, 'height': 40},
  'url': 'https://example.com',
  'title': 'Example',
});

Matcher failsWith(BrowserFailure failure) => throwsA(
  isA<BrowserException>().having((e) => e.failure, 'failure', failure),
);

({ElementPicker picker, CdpPage page, FakeCdpSocket socket}) build({
  Object? injectionResult = true,
}) {
  final socket = FakeCdpSocket();
  socket.responder = (method, params) => switch (method) {
    'Runtime.evaluate' => {
      'result': {'type': 'boolean', 'value': injectionResult},
    },
    'DOM.getDocument' => {
      'root': {'nodeId': 1},
    },
    'DOM.querySelector' => {'nodeId': 42},
    'DOM.getNodeForLocation' => {'nodeId': 55},
    'DOM.getOuterHTML' => {'outerHTML': '<button id="go">Go</button>'},
    'CSS.getComputedStyleForNode' => {
      'computedStyle': [
        {'name': 'background-color', 'value': 'rgb(37, 99, 235)'},
      ],
    },
    'Page.captureScreenshot' => {
      'data': base64Encode([1, 2, 3]),
    },
    _ => <String, Object?>{},
  };
  final page = CdpPage(
    connection: CdpConnection(
      socket,
      defaultTimeout: const Duration(milliseconds: 500),
    ),
    target: _target,
  );
  return (picker: ElementPicker(page), page: page, socket: socket);
}

void main() {
  group('installing the picker', () {
    test('brings the page forward before it arms anything', () async {
      // The pane says "Click an element in the browser…"; arming a binding on a
      // window that was never raised waits on a click the user cannot see.
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();

      final methods = fixture.socket.methods;
      expect(methods, contains('Page.bringToFront'));
      expect(
        methods.indexOf('Page.bringToFront'),
        lessThan(methods.indexOf('Runtime.addBinding')),
        reason: 'the window has to be up before the click is waited for',
      );

      fixture.picker.cancel();
      await expectLater(pending, failsWith(BrowserFailure.pickCancelled));
      await fixture.page.close();
    });

    test('adds the binding and injects the script', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();

      expect(fixture.socket.methods, contains('Runtime.addBinding'));
      expect(fixture.socket.paramsFor('Runtime.addBinding'), {
        'name': kPickerBindingName,
      });
      expect(
        fixture.socket.paramsFor('Runtime.evaluate')!['expression'],
        contains("window['$kPickerBindingName']"),
      );

      fixture.socket.emitEvent('Runtime.bindingCalled', {
        'name': kPickerBindingName,
        'payload': clickPayload(),
      });
      await pending;
      await fixture.page.close();
    });

    test('a script that does not install is reported, not waited on', () async {
      final fixture = build(injectionResult: false);
      await expectLater(
        fixture.picker.pick(),
        failsWith(BrowserFailure.evaluationFailed),
      );
      await fixture.page.close();
    });

    test(
      'two picks at once is a programming error, not a silent overwrite',
      () async {
        final fixture = build();
        final first = fixture.picker.pick();
        await pumpEventQueue();
        await expectLater(
          fixture.picker.pick(),
          failsWith(BrowserFailure.protocolError),
        );
        fixture.picker.cancel();
        await expectLater(first, failsWith(BrowserFailure.pickCancelled));
        await fixture.page.close();
      },
    );
  });

  group('a successful pick', () {
    test('turns the click into a full capture bundle', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      fixture.socket.emitEvent('Runtime.bindingCalled', {
        'name': kPickerBindingName,
        'payload': clickPayload(),
      });

      final capture = await pending;
      expect(capture.selector, '#go');
      expect(capture.tagName, 'button');
      expect(capture.outerHtml, '<button id="go">Go</button>');
      expect(capture.computedStyles['background-color'], 'rgb(37, 99, 235)');
      expect(capture.screenshotPng, [1, 2, 3]);
      expect(capture.box.width, 120);
      expect(capture.pageUrl, 'https://example.com');
      await fixture.page.close();
    });

    test(
      'a payload with no unique selector falls back to the click point',
      () async {
        final fixture = build();
        final pending = fixture.picker.pick();
        await pumpEventQueue();
        fixture.socket.emitEvent('Runtime.bindingCalled', {
          'name': kPickerBindingName,
          'payload': clickPayload(selector: null),
        });

        await pending;
        expect(fixture.socket.paramsFor('DOM.getNodeForLocation'), {
          'x': 100,
          'y': 200,
          'includeUserAgentShadowDOM': false,
        });
        await fixture.page.close();
      },
    );

    test('tears the picker down afterwards', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      fixture.socket.emitEvent('Runtime.bindingCalled', {
        'name': kPickerBindingName,
        'payload': clickPayload(),
      });
      await pending;

      expect(fixture.socket.methods, contains('Runtime.removeBinding'));
      expect(
        fixture.socket.sentFrames
            .where((f) => f['method'] == 'Runtime.evaluate')
            .map((f) => (f['params']! as Map)['expression'])
            .last,
        contains('p.stop()'),
      );
      expect(fixture.picker.isActive, isFalse);
      await fixture.page.close();
    });

    test('ignores binding calls meant for someone else', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      fixture.socket.emitEvent('Runtime.bindingCalled', {
        'name': 'someOtherBinding',
        'payload': clickPayload(selector: '#wrong'),
      });
      await pumpEventQueue();
      fixture.socket.emitEvent('Runtime.bindingCalled', {
        'name': kPickerBindingName,
        'payload': clickPayload(),
      });
      expect((await pending).selector, '#go');
      await fixture.page.close();
    });
  });

  group('backing out', () {
    test('the page reporting a cancel becomes pickCancelled', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      fixture.socket.emitEvent('Runtime.bindingCalled', {
        'name': kPickerBindingName,
        'payload': jsonEncode({'ok': false, 'cancelled': true}),
      });
      await expectLater(pending, failsWith(BrowserFailure.pickCancelled));
      await fixture.page.close();
    });

    test('cancel() from our side also reports pickCancelled', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      expect(fixture.picker.isActive, isTrue);
      fixture.picker.cancel();
      await expectLater(pending, failsWith(BrowserFailure.pickCancelled));
      expect(fixture.picker.isActive, isFalse);
      await fixture.page.close();
    });

    test('cancel() on an idle picker does nothing', () {
      final fixture = build();
      expect(fixture.picker.cancel, returnsNormally);
    });

    test('a pick nobody answers eventually times out', () async {
      final fixture = build();
      await expectLater(
        fixture.picker.pick(timeout: const Duration(milliseconds: 40)),
        failsWith(BrowserFailure.timeout),
      );
      await fixture.page.close();
    });
  });

  group('the ground moving underneath', () {
    test('a main-frame navigation kills the pick with targetGone', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      fixture.socket.emitEvent('Page.frameNavigated', {
        'frame': {'id': 'F1', 'url': 'https://elsewhere.example'},
      });
      await expectLater(
        pending,
        throwsA(
          isA<BrowserException>()
              .having((e) => e.failure, 'failure', BrowserFailure.targetGone)
              .having(
                (e) => e.message,
                'message',
                contains('https://elsewhere.example'),
              ),
        ),
      );
      await fixture.page.close();
    });

    test('an iframe navigating is not the page navigating', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      fixture.socket.emitEvent('Page.frameNavigated', {
        'frame': {'id': 'F2', 'parentId': 'F1', 'url': 'https://ads.example'},
      });
      await pumpEventQueue();
      fixture.socket.emitEvent('Runtime.bindingCalled', {
        'name': kPickerBindingName,
        'payload': clickPayload(),
      });
      expect((await pending).selector, '#go');
      await fixture.page.close();
    });

    test('a crashed target kills the pick with targetGone', () async {
      final fixture = build();
      final pending = fixture.picker.pick();
      await pumpEventQueue();
      fixture.socket.emitEvent('Inspector.targetCrashed');
      await expectLater(pending, failsWith(BrowserFailure.targetGone));
      await fixture.page.close();
    });

    test(
      'the browser closing reports disconnected, never a stale capture',
      () async {
        final fixture = build();
        final pending = fixture.picker.pick();
        await pumpEventQueue();
        fixture.socket.drop();
        await expectLater(pending, failsWith(BrowserFailure.disconnected));
      },
    );

    test(
      'teardown after a disconnect sends nothing and does not throw',
      () async {
        final fixture = build();
        final pending = fixture.picker.pick();
        await pumpEventQueue();
        final before = fixture.socket.sent.length;
        fixture.socket.drop();
        await expectLater(pending, failsWith(BrowserFailure.disconnected));
        expect(fixture.socket.sent.length, before);
      },
    );

    test(
      'a malformed payload is reported rather than parsed into nonsense',
      () async {
        final fixture = build();
        final pending = fixture.picker.pick();
        await pumpEventQueue();
        fixture.socket.emitEvent('Runtime.bindingCalled', {
          'name': kPickerBindingName,
          'payload': 'not json at all',
        });
        await expectLater(pending, failsWith(BrowserFailure.malformedResponse));
        await fixture.page.close();
      },
    );
  });
}
