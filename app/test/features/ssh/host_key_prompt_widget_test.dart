import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/ssh/application/ssh_providers.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala/src/features/ssh/presentation/host_key_changed_alert.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_prompt_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// dartssh2 hands the callback the UTF-8 of `SHA256:<base64>`.
Uint8List fp(String value) => Uint8List.fromList(utf8.encode(value));

const _good = 'SHA256:v0AsHkTEsTfInGeRpRiNtOnEoNeOnE1234567890a';
const _evil = 'SHA256:iMpOsToRiMpOsToRiMpOsToRiMpOsToR0987654321b';

void main() {
  late FakeDataServer server;
  late ProviderContainer container;
  late KnownHostsData known;

  setUp(() async {
    server = FakeDataServer(clock: () => testTime);
    final client = await server.connect();
    known = KnownHostsData(client);
    container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(client),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
  });

  /// The verifier as the connection builds it, with the app's real wiring.
  SshHostKeyVerifier verifier() => SshHostKeyVerifier(
    knownHosts: known,
    host: 'build-box',
    port: 2222,
    clock: FixedClock(testTime),
    onUnknownHostKey: container.read(hostKeyTrustDecisionProvider),
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

  testWidgets('an unknown key shows its algorithm and SHA256 fingerprint', (
    tester,
  ) async {
    await pump(tester);
    final accepted = verifier().verify('ssh-ed25519', fp(_good));
    await tester.pumpAndSettle();

    expect(find.text('Unrecognised host key'), findsOneWidget);
    expect(find.textContaining('build-box:2222'), findsWidgets);
    expect(find.text('ssh-ed25519'), findsOneWidget);
    expect(find.text(_good), findsOneWidget);
    // The command that produces the value to compare against.
    expect(
      find.text('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await accepted, isFalse);
  });

  testWidgets('accepting is gated behind an explicit confirmation', (
    tester,
  ) async {
    await pump(tester);
    final accepted = verifier().verify('ssh-ed25519', fp(_good));
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

    expect(await accepted, isTrue);
    // Accepting is what pins it — trust on first use, recorded.
    final pinned = known.find('build-box', 2222)!;
    expect(pinned.fingerprint, _good);
    expect(pinned.keyType, 'ssh-ed25519');
  });

  testWidgets('declining leaves nothing trusted', (tester) async {
    await pump(tester);
    final accepted = verifier().verify('ssh-ed25519', fp(_good));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await accepted, isFalse);
    expect(known.find('build-box', 2222), isNull);
  });

  testWidgets('a second connection with the pinned key never prompts', (
    tester,
  ) async {
    server.knownHostRows.trust(
      KnownHostKey(
        host: 'build-box',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: _good,
        trustedAt: testTime,
      ),
    );
    await pump(tester);

    expect(await verifier().verify('ssh-ed25519', fp(_good)), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Unrecognised host key'), findsNothing);
  });

  testWidgets('a changed key is refused with no dialog and no overwrite', (
    tester,
  ) async {
    server.knownHostRows.trust(
      KnownHostKey(
        host: 'build-box',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: _good,
        trustedAt: testTime,
      ),
    );
    await pump(tester);

    final v = verifier();
    expect(await v.verify('ssh-ed25519', fp(_evil)), isFalse);
    await tester.pumpAndSettle();

    // No question was asked, of anyone.
    expect(find.byType(AlertDialog), findsNothing);
    expect(v.lastPresentation!.verdict, HostKeyVerdict.changed);
    // And the pinned key is exactly as it was.
    expect(known.find('build-box', 2222)!.fingerprint, _good);
  });

  testWidgets('the changed-key alert says so plainly and can forget the key', (
    tester,
  ) async {
    server.knownHostRows.trust(
      KnownHostKey(
        host: 'build-box',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: _good,
        trustedAt: testTime,
      ),
    );
    final v = verifier();
    await v.verify('ssh-ed25519', fp(_evil));
    final presentation = v.lastPresentation!;

    var forgotten = false;
    await pump(
      tester,
      body: HostKeyChangedAlert(
        presentation: presentation,
        onForgotten: () => forgotten = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('REMOTE HOST IDENTIFICATION HAS CHANGED'), findsOneWidget);
    expect(find.text(_good), findsOneWidget); // pinned
    expect(find.text(_evil), findsOneWidget); // offered now
    // There is no way to accept the new key from here.
    expect(find.textContaining('Connect anyway'), findsNothing);
    expect(find.textContaining('Trust'), findsNothing);

    await tester.tap(find.text('Forget the pinned key…'));
    await tester.pumpAndSettle();
    expect(find.text('Forget the pinned host key?'), findsOneWidget);

    // Backing out changes nothing.
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(known.find('build-box', 2222), isNotNull);
    expect(forgotten, isFalse);

    await tester.tap(find.text('Forget the pinned key…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget it'));
    await tester.pumpAndSettle();

    expect(known.find('build-box', 2222), isNull);
    expect(forgotten, isTrue);

    // Forgetting does not trust the new key: the next connection is a first
    // connection, which asks.
    final again = verifier().verify('ssh-ed25519', fp(_evil));
    await tester.pumpAndSettle();
    expect(find.text('Unrecognised host key'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await again, isFalse);
  });

  testWidgets('with no prompt UI mounted an unknown host is still refused', (
    tester,
  ) async {
    // The unattended default Loop 37 chose, preserved: the handler exists, but
    // with nothing on screen to show a fingerprint it says no.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      ),
    );
    expect(await verifier().verify('ssh-ed25519', fp(_good)), isFalse);
    expect(known.find('build-box', 2222), isNull);
  });
}
