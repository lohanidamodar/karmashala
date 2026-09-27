import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/automation_check_runner.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_verification/verification.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// A session's project checks, asked for from the delivery strip or a
/// comparison: run by the server (slice 5c, `checks.run` — in sessions it
/// owns on its machine, as commands on an SSH box). This app only asks, shows
/// the batch busy, and reads the run the server wrote.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    server = FakeDataServer();
    container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
  });

  RunningSessionChecks checks() =>
      container.read(runningSessionChecksProvider.notifier);

  test('a repository with nothing to check answers nothing', () async {
    expect(await checks().run('s1'), isNull);
    expect(server.attention.checksAsked, ['s1']);
  });

  test('checks that ran are read back as the run the server wrote', () async {
    server.verificationRows.insertRun(
      VerificationRun(
        id: 'v1',
        title: 'Project checks',
        target: const VerificationTarget.browser('http://localhost'),
        sessionId: 's1',
        producedBySessionId: kAppVerifierId,
        startedAt: testTime,
        artifactDirectory: '/runs/v1',
      ),
    );
    server.attention.checks = (_) => const SessionChecksRun(
      SessionChecksOutcome.ran,
      verificationRunId: 'v1',
    );

    final result = await checks().run('s1');

    expect(result!.run.id, 'v1');
    expect(result.run.producedBySessionId, kAppVerifierId);
  });

  test('checks the server could not run are refused in its words', () async {
    server.attention.checks = (_) => const SessionChecksRun(
      SessionChecksOutcome.refused,
      message: 'the box did not answer',
    );

    await expectLater(
      checks().run('s1'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'the box did not answer',
        ),
      ),
    );
    expect(container.read(runningSessionChecksProvider), isEmpty);
  });

  test('a batch already running is not started twice', () async {
    final hold = Completer<void>();
    server.hold = hold;
    final first = checks().run('s1');
    expect(container.read(runningSessionChecksProvider), {'s1'});
    expect(await checks().run('s1'), isNull);
    hold.complete();
    server.hold = null;
    await first;
    expect(server.attention.checksAsked, ['s1']);
    expect(container.read(runningSessionChecksProvider), isEmpty);
  });
}
