import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala/src/features/verification/application/verification_tools.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter_test/flutter_test.dart';

import 'verification_harness.dart';
import 'verification_tools_test.dart' show textOf;

void main() {
  late VerificationHarness h;

  setUp(() => h = VerificationHarness());
  tearDown(() => h.dispose());

  group('a change is a third kind of target', () {
    test('it parses by name and unknown values still fall back', () {
      expect(
        VerificationTargetKind.parse('change'),
        VerificationTargetKind.change,
      );
      expect(
        VerificationTargetKind.parse('teleport'),
        VerificationTargetKind.browser,
      );
    });

    test('it is neither a browser nor a device, and says so', () {
      const target = VerificationTarget.change();
      expect(target.kind, VerificationTargetKind.change);
      expect(target.isBrowser, isFalse);
      expect(target.isDevice, isFalse);
      expect(target.label, isNotEmpty);
    });
  });

  group('recording a change run', () {
    test('starts without reaching for a browser or a device', () async {
      await h.service.start(
        target: const VerificationTarget.change(),
        title: 'Review of the parser fix',
        sessionId: 'work-1',
        producedBySessionId: 'review-1',
      );
      expect(h.browser.service.isConnected, isFalse);
      expect(h.browser.endpoint.openedUrl, isNull);
      expect(h.adb.calls, isEmpty);
    });

    test('the verdict is attributed to the reviewer, not the author', () async {
      await h.service.start(
        target: const VerificationTarget.change(),
        sessionId: 'work-1',
        producedBySessionId: 'review-1',
      );
      h.service.note('The retry loop never resets the counter.');
      final run = await h.service.finish(
        verdict: VerificationVerdict.fail,
        reason: 'The retry loop never resets its counter.',
        producedBySessionId: 'review-1',
      );
      expect(run.verdict, VerificationVerdict.fail);
      expect(run.attribution, VerdictAttribution.independent);
      expect(run.steps, hasLength(1));
    });

    test('finishing collects nothing from a browser or a device', () async {
      await h.service.start(
        target: const VerificationTarget.change(),
        sessionId: 'work-1',
      );
      await h.service.finish(verdict: VerificationVerdict.pass);
      expect(h.adb.calls, isEmpty);
      expect(h.browser.service.isConnected, isFalse);
    });

    test('a change run round-trips through the database', () async {
      final started = await h.service.start(
        target: const VerificationTarget.change(),
        title: 'Review of the parser fix',
        sessionId: 'work-1',
        producedBySessionId: 'review-1',
      );
      await h.service.finish(
        verdict: VerificationVerdict.pass,
        reason: 'Nothing wrong found.',
      );
      final stored = h.dao.getRun(started.id)!;
      expect(stored.target.kind, VerificationTargetKind.change);
      expect(stored.sessionId, 'work-1');
      expect(stored.producedBySessionId, 'review-1');
      expect(stored.verdict, VerificationVerdict.pass);
    });
  });

  group('verification_start over MCP', () {
    test('change:true records the caller as the verifier', () async {
      final tools = VerificationTools(h.service, callerSessionId: 'review-1');
      final result = await tools.call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
        'title': 'Review of the parser fix',
      });
      final run = h.service.activeRun!;
      expect(run.target.kind, VerificationTargetKind.change);
      expect(run.sessionId, 'work-1');
      expect(run.producedBySessionId, 'review-1');
      expect(textOf(result), contains('independent'));
    });

    test('a change run cannot also be a page run', () async {
      final tools = VerificationTools(h.service);
      await expectLater(
        tools.call('verification_start', {
          'change': true,
          'url': 'localhost:3000',
        }),
        throwsA(isA<VerificationException>()),
      );
    });

    test('naming nothing at all points at all three kinds', () async {
      final tools = VerificationTools(h.service);
      await expectLater(
        tools.call('verification_start', const {}),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('change'),
          ),
        ),
      );
    });
  });
}
