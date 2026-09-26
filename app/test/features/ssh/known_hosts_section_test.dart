import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala/src/features/ssh/presentation/known_hosts_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

const _fingerprint = 'SHA256:pInNeDpInNeDpInNeDpInNeDpInNeDpInNeD012345';

void main() {
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    server = FakeDataServer();
    data = await server.override();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [data],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: KnownHostsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty store explains when a key gets pinned', (tester) async {
    await pump(tester);
    expect(find.textContaining('only if you accept it'), findsOneWidget);
  });

  testWidgets('a pinned key is shown in full so it can be audited', (
    tester,
  ) async {
    server.knownHostRows.trust(
      KnownHostKey(
        host: 'build-box',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: _fingerprint,
        trustedAt: testTime,
      ),
    );
    await pump(tester);

    expect(find.text('build-box:2222'), findsOneWidget);
    expect(find.textContaining(_fingerprint), findsOneWidget);
    expect(find.textContaining('ssh-ed25519'), findsOneWidget);
  });

  testWidgets('forgetting a key is confirmed, and unpins nothing else', (
    tester,
  ) async {
    for (final port in [2222, 22]) {
      server.knownHostRows.trust(
        KnownHostKey(
          host: 'build-box',
          port: port,
          keyType: 'ssh-ed25519',
          fingerprint: '$_fingerprint$port',
          trustedAt: testTime,
        ),
      );
    }
    await pump(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Forget').first);
    await tester.pumpAndSettle();
    expect(find.text('Forget the pinned host key?'), findsOneWidget);
    // The wording has to make clear this is not an acceptance of a new key.
    expect(find.textContaining('asked whether to trust it'), findsOneWidget);

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(server.knownHostRows.getAll(), hasLength(2));

    await tester.tap(find.widgetWithText(TextButton, 'Forget').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget it'));
    await tester.pumpAndSettle();

    // `host:port` is the identity: the same machine on another port keeps its
    // own pinned key.
    final left = server.knownHostRows.getAll().single;
    expect(left.port, 2222);
    expect(find.text('build-box:22'), findsNothing);
  });
}
