import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/github_access/presentation/github_access_page.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';

/// Settings → Source control → GitHub: a token typed once and never shown
/// again, tested against GitHub's `/user` (here the fake server's), and each
/// host's gh account or Off — at a phone's width and text scale too.
void main() {
  late FakeDataServer server;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 1000),
    double textScale = 1,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final data = await server.override();
    final container = ProviderContainer(overrides: [data]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Scaffold(
              body: SingleChildScrollView(child: GithubAccessPage()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    server = FakeDataServer(clock: () => DateTime.utc(2026, 10, 8));
    server.github.status = const GithubAccessStatus(
      hosts: [
        GithubHostAccess(
          host: 'github.com',
          status: 'Using gh as @me',
          source: 'gh',
          login: 'me',
          ghAccounts: ['me', 'work'],
          ghActiveAccount: 'me',
        ),
        GithubHostAccess(
          host: 'ghe.corp.example',
          status: 'Using gh as @corp',
          source: 'gh',
          ghAccounts: ['corp'],
          ghActiveAccount: 'corp',
        ),
      ],
    );
    server.github.logins['ghp_pasted'] = 'octo';
  });

  testWidgets('each host says where its access comes from', (tester) async {
    await pump(tester);
    expect(find.text('Using gh as @me'), findsOneWidget);
    expect(find.text('Using gh as @corp'), findsOneWidget);
    expect(server.github.requests.first, isA<GithubAccessRead>());
  });

  testWidgets('Save sends the token once, then shows only that one is saved; '
      'Test names who it is', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('github-token-value')),
      'ghp_pasted',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(server.github.savedTokens['github.com'], 'ghp_pasted');
    expect(find.textContaining('ghp_pasted'), findsNothing);
    expect(find.text('Saved · not tested yet'), findsOneWidget);
    expect(find.text('Using your saved token'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub says this is @octo.'), findsOneWidget);
    expect(find.text('Saved · last checked as @octo'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(server.github.savedTokens, isEmpty);
    expect(find.text('Saved · last checked as @octo'), findsNothing);
  });

  testWidgets('a token GitHub refuses fails its test in words', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('github-token-value')),
      'ghp_wrong',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 401'), findsOneWidget);
  });

  testWidgets('a host picks its gh account, or is turned off', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('github-account-github.com')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@work').last);
    await tester.pumpAndSettle();
    final chose = server.github.requests.whereType<GithubHostChoose>().last;
    expect(chose.host, 'github.com');
    expect(chose.account, 'work');
    expect(chose.off, isFalse);

    await tester.tap(
      find.byKey(const ValueKey('github-account-ghe.corp.example')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off — no GitHub on this host').last);
    await tester.pumpAndSettle();
    final off = server.github.requests.whereType<GithubHostChoose>().last;
    expect(off.host, 'ghe.corp.example');
    expect(off.off, isTrue);
    expect(find.text('GitHub is turned off for ghe.corp.example'), findsOneWidget);
  });

  for (final (name, size, scale) in [
    ('a 360 px phone at text scale 1.6', const Size(360, 1600), 1.6),
    ('a wide desktop', const Size(1600, 1000), 1.0),
  ]) {
    testWidgets('lays out without overflow on $name', (tester) async {
      await pump(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('ghe.corp.example'), findsOneWidget);
    });
  }
}
