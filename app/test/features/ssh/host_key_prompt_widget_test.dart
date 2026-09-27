import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/ssh/data/ssh_hosts_data.dart';
import 'package:karmashala/src/features/ssh/presentation/host_key_changed_alert.dart';
import 'package:karmashala/src/features/ssh/application/ssh_prompt_controller.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_prompt_host.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

const _good = 'SHA256:v0AsHkTEsTfInGeRpRiNtOnEoNeOnE1234567890a';
const _evil = 'SHA256:iMpOsToRiMpOsToRiMpOsToRiMpOsToR0987654321b';

/// A host key the server's connection was offered, as a window shows it
/// (slice 3a; since 5d every connection is the server's): the algorithm and
/// fingerprint, a trust gated behind a confirmation, a decline sent back as
/// one, and a changed key's alert that can only forget the pinned key.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    server = FakeDataServer(clock: () => testTime);
    final client = await server.connect();
    container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(client),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    container.read(sshPromptControllerProvider);
  });

  SshPromptOpened unknownKey() => const SshPromptOpened(
    promptId: 'p1',
    hostId: 'h1',
    hostName: 'build-box',
    address: 'dev@build-box:2222',
    kind: SshPromptKind.hostKey,
    presentation: HostKeyPresentation(
      host: 'build-box',
      port: 2222,
      keyType: 'ssh-ed25519',
      fingerprint: _good,
      verdict: HostKeyVerdict.unknown,
    ),
  );

  Future<void> pump(WidgetTester tester, {Widget? body}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: SshPromptHost(
            child: Scaffold(body: body ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an unknown key shows its algorithm and SHA256 fingerprint, and '
      'a cancel is sent back as a refusal', (tester) async {
    await pump(tester);
    server.sshWork.tell([unknownKey()]);
    await tester.pumpAndSettle();

    expect(find.text('Unrecognised host key'), findsOneWidget);
    expect(find.textContaining('build-box:2222'), findsWidgets);
    expect(find.text('ssh-ed25519'), findsOneWidget);
    expect(find.text(_good), findsOneWidget);
    expect(
      find.text('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.runAsync(pumpEventQueue);
    expect(server.sshWork.answers.single.trust, isFalse);
  });

  testWidgets('trusting is gated behind an explicit confirmation', (
    tester,
  ) async {
    await pump(tester);
    server.sshWork.tell([unknownKey()]);
    await tester.pumpAndSettle();

    final trust = find.widgetWithText(FilledButton, 'Trust this key');
    expect(tester.widget<FilledButton>(trust).onPressed, isNull);

    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(trust).onPressed, isNotNull);

    await tester.tap(trust);
    await tester.pumpAndSettle();
    await tester.runAsync(pumpEventQueue);
    expect(server.sshWork.answers.single.trust, isTrue);
  });

  testWidgets('the changed-key alert says so plainly and can only forget the '
      'pinned key', (tester) async {
    final pinned = KnownHostKey(
      host: 'build-box',
      port: 2222,
      keyType: 'ssh-ed25519',
      fingerprint: _good,
      trustedAt: testTime,
    );
    server.knownHostRows.trust(pinned);
    final known = container.read(knownHostsDataProvider);
    var forgotten = false;
    await pump(
      tester,
      body: HostKeyChangedAlert(
        presentation: HostKeyPresentation(
          host: 'build-box',
          port: 2222,
          keyType: 'ssh-ed25519',
          fingerprint: _evil,
          verdict: HostKeyVerdict.changed,
          known: pinned,
        ),
        onForgotten: () => forgotten = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('REMOTE HOST IDENTIFICATION HAS CHANGED'), findsOneWidget);
    expect(find.text(_good), findsOneWidget); // pinned
    expect(find.text(_evil), findsOneWidget); // offered now
    expect(find.textContaining('Connect anyway'), findsNothing);
    expect(find.textContaining('Trust'), findsNothing);

    await tester.tap(find.text('Forget the pinned key…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(known.find('build-box', 2222), isNotNull);
    expect(forgotten, isFalse);

    await tester.tap(find.text('Forget the pinned key…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget it'));
    await tester.pumpAndSettle();
    await tester.runAsync(pumpEventQueue);
    expect(known.find('build-box', 2222), isNull);
    expect(forgotten, isTrue);
  });
}
