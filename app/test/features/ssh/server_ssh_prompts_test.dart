import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/data/ssh_client.dart';
import 'package:karmashala/src/features/ssh/application/ssh_prompt_controller.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_connection_status_chip.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_prompt_host.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';

import '../../support/fake_data_server.dart';

/// The server's SSH questions and connection states, as this app is a client
/// of them (slice 3a): a question the server opens is shown, the answer goes
/// back as `ssh.answerPrompt`, one another window answered closes here, and
/// the chip reads the server's connection.
void main() {
  const opened = SshPromptOpened(
    promptId: 'p1',
    hostId: 'h1',
    hostName: 'build-box',
    address: 'dev@build-box:22',
    kind: SshPromptKind.password,
  );
  const hostKey = SshPromptOpened(
    promptId: 'p2',
    hostId: 'h1',
    hostName: 'build-box',
    address: 'dev@build-box:22',
    kind: SshPromptKind.hostKey,
    presentation: HostKeyPresentation(
      host: 'build-box',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:AAAA',
      verdict: HostKeyVerdict.unknown,
    ),
  );

  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    server = FakeDataServer();
    container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    container.read(sshPromptControllerProvider);
  });

  List<ServerSshPrompt> queue() => container.read(sshPromptControllerProvider);

  test('a question the server opens is queued, and the answer goes back '
      'to it', () async {
    server.sshWork.tell([opened]);
    await pumpEventQueue();
    final request = queue().single;
    expect(request.opened.address, 'dev@build-box:22');

    await container
        .read(sshPromptControllerProvider.notifier)
        .answerServer(request, secret: 'hunter2');

    expect(queue(), isEmpty);
    final answer = server.sshWork.answers.single;
    expect(answer.promptId, 'p1');
    expect(answer.secret, 'hunter2');
    expect('$answer', isNot(contains('hunter2')));
  });

  test('one another window answered is closed here', () async {
    server.sshWork.tell([opened]);
    await pumpEventQueue();
    final request = queue().single;

    server.sshWork.tell([const SshPromptClosed('p1')]);
    await pumpEventQueue();

    expect(queue(), isEmpty);
    expect(request.isAnswered, isTrue);
    expect(server.sshWork.answers, isEmpty);
  });

  test('the same question told twice is shown once', () async {
    server.sshWork.tell([opened]);
    server.sshWork.tell([opened]);
    await pumpEventQueue();
    expect(queue(), hasLength(1));
  });

  testWidgets('a host key question is shown, and a trust is sent', (
    tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SshPromptHost(child: Scaffold(body: SizedBox())),
        ),
      ),
    );
    server.sshWork.tell([hostKey]);
    await tester.pumpAndSettle();
    expect(find.textContaining('SHA256:AAAA'), findsWidgets);

    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Trust this key'));
    await tester.pumpAndSettle();
    await tester.runAsync(pumpEventQueue);

    final answer = server.sshWork.answers.single;
    expect(answer.promptId, 'p2');
    expect(answer.trust, isTrue);
  });

  testWidgets('a dialog for a question another window answered goes away', (
    tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SshPromptHost(child: Scaffold(body: SizedBox())),
        ),
      ),
    );
    server.sshWork.tell([opened]);
    await tester.pumpAndSettle();
    expect(find.textContaining('dev@build-box:22'), findsWidgets);

    server.sshWork.tell([const SshPromptClosed('p1')]);
    await tester.pumpAndSettle();

    expect(find.textContaining('dev@build-box:22'), findsNothing);
    expect(server.sshWork.answers, isEmpty);
  });

  testWidgets('the chip reads the server\'s connection', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SshConnectionStatusChip(hostId: 'h1')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Not connected'), findsOneWidget);

    server.sshWork.tell([
      const SshConnectionChanged(
        'h1',
        SshConnectionState(status: SshConnectionStatus.connected),
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);
    expect(
      container.read(sshConnectionStateProvider('h1')).value?.status,
      SshConnectionStatus.connected,
    );
  });
}
