import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/ssh/application/ssh_prompt_controller.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host_key.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _other = 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

HostKeyPresentation presentation({
  HostKeyVerdict verdict = HostKeyVerdict.unknown,
  KnownHostKey? known,
}) => HostKeyPresentation(
  host: 'build-box',
  port: 2222,
  keyType: 'ssh-ed25519',
  fingerprint: _fingerprint,
  verdict: verdict,
  known: known,
);

SshHost host() => SshHost(
  id: 'h1',
  name: 'build-box',
  host: 'build-box',
  port: 2222,
  username: 'dev',
  authMethod: SshAuthMethod.password,
  privateKey: const EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\keys\id',
  ),
  createdAt: testTime,
);

void main() {
  late ProviderContainer container;
  late SshPromptController controller;

  setUp(() {
    container = ProviderContainer();
    controller = container.read(sshPromptControllerProvider.notifier);
  });
  tearDown(() => container.dispose());

  test('an unknown host key is refused when no UI is mounted', () async {
    expect(controller.canAsk, isFalse);
    expect(await controller.askHostKey(presentation()), isFalse);
    expect(container.read(sshPromptControllerProvider), isEmpty);
  });

  test('a secret is refused when no UI is mounted', () async {
    expect(await controller.askSecret(host(), SshSecretKind.password), isNull);
  });

  test('with a UI mounted an unknown key becomes a queued question', () async {
    controller.attach();
    final answer = controller.askHostKey(presentation());

    final queue = container.read(sshPromptControllerProvider);
    expect(queue, hasLength(1));
    final request = queue.single as HostKeyPromptRequest;
    expect(request.presentation.fingerprint, _fingerprint);
    expect(request.presentation.keyType, 'ssh-ed25519');

    controller.answerHostKey(request, trusted: true);
    expect(await answer, isTrue);
    expect(container.read(sshPromptControllerProvider), isEmpty);
  });

  test('declining resolves to false', () async {
    controller.attach();
    final answer = controller.askHostKey(presentation());
    final request =
        container.read(sshPromptControllerProvider).single
            as HostKeyPromptRequest;
    controller.answerHostKey(request, trusted: false);
    expect(await answer, isFalse);
  });

  test('a changed key is never turned into a question', () async {
    // The verifier already refuses a changed key without calling any handler.
    // This is the second lock: even if something routed one here, there is no
    // path that shows a user a dialog they could answer "yes" to.
    controller.attach();
    final changed = presentation(
      verdict: HostKeyVerdict.changed,
      known: KnownHostKey(
        host: 'build-box',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: _other,
        trustedAt: testTime,
      ),
    );
    expect(await controller.askHostKey(changed), isFalse);
    expect(container.read(sshPromptControllerProvider), isEmpty);
  });

  test('a trusted key is not queued either', () async {
    controller.attach();
    expect(
      await controller.askHostKey(
        presentation(verdict: HostKeyVerdict.trusted),
      ),
      isFalse,
    );
    expect(container.read(sshPromptControllerProvider), isEmpty);
  });

  test('losing the UI refuses everything still waiting', () async {
    controller.attach();
    final key = controller.askHostKey(presentation());
    final secret = controller.askSecret(host(), SshSecretKind.passphrase);
    expect(container.read(sshPromptControllerProvider), hasLength(2));

    controller.detach();

    expect(await key, isFalse);
    expect(await secret, isNull);
    expect(container.read(sshPromptControllerProvider), isEmpty);
    expect(controller.canAsk, isFalse);
  });

  test('mounts are counted, so a rebuild never drops the ability to ask', () {
    controller.attach();
    controller.attach();
    controller.detach();
    expect(controller.canAsk, isTrue);
    controller.detach();
    expect(controller.canAsk, isFalse);
  });

  test('a cancelled secret prompt resolves to null', () async {
    controller.attach();
    final answer = controller.askSecret(host(), SshSecretKind.password);
    final request =
        container.read(sshPromptControllerProvider).single
            as SshSecretPromptRequest;
    expect(request.kind, SshSecretKind.password);
    expect(request.host.address, 'dev@build-box:2222');
    controller.answerSecret(request, null);
    expect(await answer, isNull);
  });

  test('prompts queue in arrival order', () async {
    controller.attach();
    final first = controller.askSecret(host(), SshSecretKind.password);
    final second = controller.askHostKey(presentation());
    final queue = container.read(sshPromptControllerProvider);
    expect(queue.first, isA<SshSecretPromptRequest>());
    expect(queue.last, isA<HostKeyPromptRequest>());
    controller.answerSecret(queue.first as SshSecretPromptRequest, 'hunter2');
    controller.answerHostKey(
      queue.last as HostKeyPromptRequest,
      trusted: false,
    );
    expect(await first, 'hunter2');
    expect(await second, isFalse);
  });
}
