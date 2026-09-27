import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host/src/ssh/prompts/ssh_prompts.dart';
import 'package:karmashala_ssh/connection.dart' show SshConnectionException;
import 'package:test/test.dart';

/// The questions the server's SSH connections put to a person: told to the
/// desktop clients, the first answer wins, nobody connected is a refusal in
/// words, and a changed key is never a question.
void main() {
  final host = SshHost(
    id: 'h1',
    name: 'box',
    host: '203.0.113.9',
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.password,
    createdAt: DateTime.utc(2026, 9, 27),
  );
  const unknown = HostKeyPresentation(
    host: '203.0.113.9',
    port: 22,
    keyType: 'ssh-ed25519',
    fingerprint: 'SHA256:abc',
    verdict: HostKeyVerdict.unknown,
  );

  late List<DataChange> told;
  late bool clients;
  late SshPrompts prompts;

  setUp(() {
    told = [];
    clients = true;
    prompts = SshPrompts(tell: told.addAll, canAsk: () => clients);
  });
  tearDown(() => prompts.close());

  SshPromptOpened opened() => told.whereType<SshPromptOpened>().single;

  test('an unknown key is told to the clients and trusted on yes', () async {
    final answer = prompts.askHostKey(host, unknown);
    final prompt = opened();
    expect(prompt.kind, SshPromptKind.hostKey);
    expect(prompt.hostId, 'h1');
    expect(prompt.presentation!.fingerprint, 'SHA256:abc');
    expect(prompts.open, hasLength(1));

    prompts.answer(SshAnswerPrompt(prompt.promptId, trust: true));

    expect(await answer, isTrue);
    expect(told.last, isA<SshPromptClosed>());
    expect(prompts.open, isEmpty);
  });

  test('the first answer wins; a later one is refused', () async {
    final answer = prompts.askSecret(host, SshPromptKind.password);
    final id = opened().promptId;
    prompts.answer(SshAnswerPrompt(id, secret: 'first'));
    expect(
      () => prompts.answer(SshAnswerPrompt(id, secret: 'second')),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
    expect(await answer, 'first');
  });

  test('no secret is ever in what the clients are told', () async {
    final answer = prompts.askSecret(host, SshPromptKind.passphrase);
    prompts.answer(SshAnswerPrompt(opened().promptId, secret: 'hunter2'));
    await answer;
    for (final change in told) {
      expect('${change.toJson()}', isNot(contains('hunter2')));
    }
  });

  test('with nobody connected it fails in words saying where to answer', () {
    clients = false;
    expect(
      () => prompts.askSecret(host, SshPromptKind.password),
      throwsA(
        isA<SshConnectionException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('dev@203.0.113.9:22'),
            contains('Open Karmashala on any device'),
          ),
        ),
      ),
    );
    expect(told, isEmpty);
  });

  test('a changed key is refused without asking', () async {
    final changed = HostKeyPresentation(
      host: unknown.host,
      port: unknown.port,
      keyType: unknown.keyType,
      fingerprint: 'SHA256:other',
      verdict: HostKeyVerdict.changed,
    );
    expect(await prompts.askHostKey(host, changed), isFalse);
    expect(told, isEmpty);
  });

  test('a question nobody answers is refused and closed', () async {
    final short = SshPrompts(
      tell: told.addAll,
      canAsk: () => true,
      wait: const Duration(milliseconds: 20),
    );
    expect(await short.askHostKey(host, unknown), isFalse);
    expect(told.last, isA<SshPromptClosed>());
    expect(short.open, isEmpty);
  });

  test('stopping refuses what is still open', () async {
    final answer = prompts.askSecret(host, SshPromptKind.password);
    prompts.close();
    expect(await answer, isNull);
  });
}
