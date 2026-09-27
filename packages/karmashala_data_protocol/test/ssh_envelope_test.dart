import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:test/test.dart';

/// SSH reached by the server (slice 3a): the test, the disconnect and a
/// prompt's answer, and what the clients are told — through the envelope as
/// JSON text. A secret goes client → server in one request and nowhere else.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 8);
  final draft = SshHost(
    id: 'h1',
    name: 'box',
    host: '203.0.113.9',
    port: 2222,
    username: 'dev',
    authMethod: SshAuthMethod.privateKey,
    privateKey: const EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\keys\id',
    ),
    createdAt: t0,
  );
  const unknown = HostKeyPresentation(
    host: '203.0.113.9',
    port: 2222,
    keyType: 'ssh-ed25519',
    fingerprint: 'SHA256:abc',
    verdict: HostKeyVerdict.unknown,
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const SshTest(hostId: 'h1'),
      SshTest(draft: draft),
      const SshDisconnect('h1'),
      const SshAnswerPrompt('p1', trust: true),
      const SshAnswerPrompt('p2', secret: 'hunter2'),
      const SshAnswerPrompt('p3'),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request, isA<SshWorkRequest<Object?>>());
      expect(
        jsonEncode(read.request!.argumentsToJson()),
        jsonEncode(request.argumentsToJson()),
        reason: request.kind,
      );
    }
    final back =
        DataEnvelope.readRequest(
              overTheWire(DataEnvelope.request(3, SshTest(draft: draft))),
            ).request!
            as SshTest;
    expect(back.draft, draft);
  });

  test('a request prints its kind, never the secret it carries', () {
    const answer = SshAnswerPrompt('p2', secret: 'hunter2');
    expect('$answer', isNot(contains('hunter2')));
    expect('$answer', contains('ssh.answerPrompt'));
  });

  test('a test result carries the refused key it met', () {
    final reply = DataEnvelope.readAnswer(
      overTheWire(
        DataEnvelope.answer(
          4,
          const SshTest(hostId: 'h1'),
          const DataReply(
            SshTestResult(
              connected: false,
              message: 'The authenticity cannot be established.',
              elapsed: Duration(milliseconds: 120),
              rejectedKey: unknown,
            ),
            9,
            [],
          ),
        ),
      ),
      const SshTest(hostId: 'h1'),
    );
    final result = reply.value;
    expect(result.connected, isFalse);
    expect(result.elapsed, const Duration(milliseconds: 120));
    expect(result.rejectedKey!.fingerprint, 'SHA256:abc');
    expect(result.rejectedKey!.verdict, HostKeyVerdict.unknown);
  });

  test('connection states and prompts are told, without any secret', () {
    final batch = DataChanges(5, [
      const SshConnectionChanged(
        'h1',
        SshConnectionState(
          status: SshConnectionStatus.disconnected,
          error: 'The remote host closed the connection.',
          attempt: 2,
          nextRetryIn: Duration(seconds: 1),
        ),
      ),
      const SshPromptOpened(
        promptId: 'p1',
        hostId: 'h1',
        hostName: 'box',
        address: 'dev@203.0.113.9:2222',
        kind: SshPromptKind.hostKey,
        presentation: unknown,
      ),
      const SshPromptOpened(
        promptId: 'p2',
        hostId: 'h1',
        hostName: 'box',
        address: 'dev@203.0.113.9:2222',
        kind: SshPromptKind.password,
      ),
      const SshPromptClosed('p1'),
    ]);
    final text = jsonEncode(DataEnvelope.changes(batch));
    final back = DataEnvelope.readChanges(
      (jsonDecode(text) as Map).cast<String, Object?>(),
    );
    final state = back.changes[0] as SshConnectionChanged;
    expect(state.hostId, 'h1');
    expect(state.state.status, SshConnectionStatus.disconnected);
    expect(state.state.attempt, 2);
    expect(state.state.nextRetryIn, const Duration(seconds: 1));
    final key = back.changes[1] as SshPromptOpened;
    expect(key.kind, SshPromptKind.hostKey);
    expect(key.presentation!.fingerprint, 'SHA256:abc');
    final password = back.changes[2] as SshPromptOpened;
    expect(password.kind, SshPromptKind.password);
    expect(password.presentation, isNull);
    expect((back.changes[3] as SshPromptClosed).promptId, 'p1');
  });
}
