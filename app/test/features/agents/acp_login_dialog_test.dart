import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/acp_login_dialog.dart';
import 'package:karmashala/src/features/agents/presentation/acp_login_progress_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// Logging in to an ACP agent never sits on "loading": a login under way
/// says its method, shows the link and code the agent gave with Copy and
/// Open, and can always be cancelled; one the agent says nothing of for two
/// minutes is ended with Retry; an error is the agent's own words; a
/// terminal login waits for its terminal; a late answer closes the dialog.
/// On a 360 px phone at text scale 1.6 and on a desktop alike.
void main() {
  late TestMachine db;

  const link =
      'https://accounts.google.com/o/oauth2/v2/auth?response_type=code'
      '&redirect_uri=http%3A%2F%2F127.0.0.1%3A45821%2F&state=s1';

  const methods = AcpAuthMethods(
    installationId: 'ag1',
    methods: [
      AcpAuthMethod(
        id: 'oauth-personal',
        name: 'Log in with Google',
        description: 'Log in with your Google account',
        completes:
            'Gives a Google sign-in link; finish it in a browser on the '
            'machine Antigravity runs on, which it returns to.',
      ),
      AcpAuthMethod(
        id: kAcpOwnTerminalLoginId,
        name: 'Sign in with a device code',
        terminal: true,
        completes: 'Opens a terminal running `grok login --device-auth`.',
      ),
    ],
  );

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.agentWork.acpAuthMethods['ag1'] = methods;
  });

  late List<AcpLoginOutcome?> popped;
  List<String?> said() => [for (final outcome in popped) outcome?.said];

  Future<void> open(WidgetTester tester) async {
    popped = [];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [await db.server.override()],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => popped.add(
                  await AcpLoginDialog.show(
                    context,
                    installationId: 'ag1',
                    agentName: 'Antigravity',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Log in to Antigravity'), findsOneWidget);
  }

  /// Starts [method] and lets the request reach the server.
  Future<void> pick(WidgetTester tester, String method) async {
    await tester.tap(find.text(method));
    await tester.pump();
    await tester.pump();
  }

  void hold() => db.server.agentWork.acpLoginGate = Completer<void>();

  void tell({String? link, String? code, String? terminal, String? method}) =>
      db.server.agentWork.tellLoginProgress(
        AcpLoginProgress(
          installationId: 'ag1',
          methodId: method ?? 'oauth-personal',
          link: link,
          code: code,
          terminal: terminal,
        ),
      );

  testWidgets('each method says how it completes before it starts', (
    tester,
  ) async {
    await open(tester);
    expect(find.textContaining('Google sign-in link'), findsOneWidget);
    expect(find.textContaining('grok login --device-auth'), findsOneWidget);
  });

  testWidgets('a login that never answers shows its method and can be '
      'cancelled, which ends it at the server', (tester) async {
    hold();
    await open(tester);
    await pick(tester, 'Log in with Google');
    expect(find.byType(AcpLoginProgressView), findsOneWidget);
    expect(find.text('Log in with Google'), findsOneWidget);
    expect(
      find.text(AcpLoginDialog.waitingNote('Log in with Google')),
      findsOneWidget,
    );
    final cancel = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Cancel'),
    );
    expect(cancel.onPressed, isNotNull, reason: 'never disabled');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(db.server.agentWork.acpCancels, ['ag1']);
    expect(find.text('Log in to Antigravity'), findsNothing);
    expect(said(), [null]);
  });

  testWidgets('a login the agent says nothing of for two minutes is ended '
      'with words and Retry', (tester) async {
    hold();
    await open(tester);
    await pick(tester, 'Log in with Google');
    await tester.pump(kAcpLoginQuietPatience);
    await tester.pump();
    expect(db.server.agentWork.acpCancels, ['ag1']);
    expect(
      find.text(AcpLoginDialog.quietNote('Antigravity', 'Log in with Google')),
      findsOneWidget,
    );
    expect(find.byType(AcpLoginProgressView), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(db.server.agentWork.acpAuthenticates, [
      ('ag1', 'oauth-personal'),
    ], reason: 'the retry was answered; the held one was cancelled first');
    expect(said(), ['Logged in via Log in with Google.']);
  });

  testWidgets('a link and a code the agent gives are shown with Copy and '
      'Open, and a link that returns to the agent\'s machine says so; the '
      'quiet timer stops once it has spoken', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    hold();
    await open(tester);
    await pick(tester, 'Log in with Google');
    tell(link: link, code: 'AB12-CD34');
    await tester.pump();
    expect(find.text(link), findsOneWidget);
    expect(find.text('AB12-CD34'), findsOneWidget);
    expect(find.text('Open in browser'), findsOneWidget);
    expect(find.text(AcpLoginProgressView.returnsLocallyNote), findsOneWidget);
    expect(find.text(AcpLoginDialog.linkNote()), findsOneWidget);

    await tester.tap(find.text('Copy link'));
    await tester.tap(find.text('Copy code'));
    await tester.pump();
    expect(copied, [link, 'AB12-CD34']);

    await tester.pump(kAcpLoginQuietPatience * 2);
    expect(db.server.agentWork.acpCancels, isEmpty);
    expect(find.text(link), findsOneWidget);

    db.server.agentWork.acpLoginGate!.complete();
    await tester.pumpAndSettle();
    expect(said(), ['Logged in via Log in with Google.']);
  });

  testWidgets('a late answer closes the dialog with what was done', (
    tester,
  ) async {
    hold();
    await open(tester);
    await pick(tester, 'Log in with Google');
    await tester.pump(const Duration(seconds: 90));
    db.server.agentWork.acpLoginGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Log in to Antigravity'), findsNothing);
    expect(said(), ['Logged in via Log in with Google.']);
  });

  testWidgets('an error is the agent\'s own words, with Retry', (tester) async {
    db.server.agentWork.acpAuthRefusal = const DataRefused(
      DataRefusalCode.failed,
      'Antigravity refused Log in with Google: your organisation does not '
      'allow this',
    );
    await open(tester);
    await pick(tester, 'Log in with Google');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('your organisation does not allow this'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(said(), ['Logged in via Log in with Google.']);
  });

  testWidgets('a terminal sign-in is handed to its tab once it opens, so the '
      'dialog never covers the terminal; the server goes on waiting', (
    tester,
  ) async {
    hold();
    await open(tester);
    await pick(tester, 'Sign in with a device code');
    expect(
      find.text('Opening a terminal for Sign in with a device code…'),
      findsOneWidget,
    );
    await tester.pump(kAcpLoginQuietPatience * 2);
    expect(db.server.agentWork.acpCancels, isEmpty, reason: 'no quiet timer');

    tell(method: kAcpOwnTerminalLoginId, terminal: 'Grok: Sign in');
    await tester.pumpAndSettle();
    expect(find.text('Log in to Antigravity'), findsNothing);
    expect(said(), [AcpLoginDialog.terminalNote('Grok: Sign in')]);
    expect(popped.single!.done, isFalse);
    expect(db.server.agentWork.acpCancels, isEmpty, reason: 'handed off');
    db.server.agentWork.acpLoginGate!.complete();
    await tester.pumpAndSettle();
    expect(db.server.agentWork.acpTerminalLogins, [
      ('ag1', kAcpOwnTerminalLoginId),
    ]);
  });

  testWidgets('a terminal login answered before its tab is told closes with '
      'its result, done', (tester) async {
    await open(tester);
    await pick(tester, 'Sign in with a device code');
    await tester.pumpAndSettle();
    expect(said(), ['Sign in with a device code finished in the terminal.']);
    expect(popped.single!.done, isTrue);
  });

  for (final (name, size, scale) in [
    ('a 360 px phone at text scale 1.6', const Size(360, 780), 1.6),
    ('a desktop', const Size(1440, 900), 1.0),
  ]) {
    testWidgets('the methods and a login with its link and code fit $name', (
      tester,
    ) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      hold();
      await open(tester);
      expect(tester.takeException(), isNull);
      await pick(tester, 'Log in with Google');
      tell(link: link, code: 'AB12-CD34');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
  }
}
