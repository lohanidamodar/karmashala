import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/acp_login_controller.dart';
import 'package:karmashala/src/features/agents/presentation/acp_login_line.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// An ACP installation's login on its Settings row: Log in lists the methods
/// the agent advertises; an agent method is the agent's `authenticate`, an
/// API-key method asks for the key and keeps it in the vault, a terminal
/// method opens a terminal. "Logged in via" only once the agent confirmed
/// it; Switch method and Forget once one is remembered. Never an account.
void main() {
  late TestMachine db;

  const methods = AcpAuthMethods(
    installationId: 'ag1',
    supportsLogout: true,
    methods: [
      AcpAuthMethod(
        id: 'oauth-personal',
        name: 'Log in with Google',
        description: 'Opens a browser on that machine.',
      ),
      AcpAuthMethod(
        id: 'gemini-api-key',
        name: 'Use Gemini API key',
        apiKeyVariable: 'GEMINI_API_KEY',
      ),
      AcpAuthMethod(id: 'login', name: 'Log in in a terminal', terminal: true),
    ],
  );

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.agentWork.acpAuthMethods['ag1'] = methods;
  });

  Future<void> pump(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [await db.server.override(), ...overrides],
        child: const MaterialApp(
          home: Scaffold(
            body: AcpLoginLine(installationId: 'ag1', agentName: 'Antigravity'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openLogin(
    WidgetTester tester, {
    String label = 'Log in…',
  }) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text('Log in to Antigravity'), findsOneWidget);
  }

  testWidgets('nothing remembered offers Log in; an agent method is '
      'authenticated and then said as the method, never an account', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Not logged in through Karmashala'), findsOneWidget);
    expect(find.text('Forget'), findsNothing);

    await openLogin(tester);
    expect(find.text('Log in with Google'), findsOneWidget);
    expect(find.text('Opens a browser on that machine.'), findsOneWidget);
    expect(find.text('In a terminal'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);

    await tester.tap(find.text('Log in with Google'));
    await tester.pumpAndSettle();
    expect(db.server.agentWork.acpAuthenticates, [('ag1', 'oauth-personal')]);
    expect(find.text('Log in to Antigravity'), findsNothing);
    expect(find.text('Logged in via Log in with Google'), findsOneWidget);
    expect(find.text('Switch method…'), findsOneWidget);
    expect(find.text('Forget'), findsOneWidget);
    expect(find.textContaining('signed in as'), findsNothing);
  });

  testWidgets('while the agent logs itself in, the dialog says to finish '
      'in the browser and how long the login waits', (tester) async {
    final hold = Completer<String>();
    await pump(
      tester,
      overrides: [
        acpLoginActionsProvider.overrideWith(
          (ref) => _HeldLogin(ref, hold.future),
        ),
      ],
    );
    await openLogin(tester);
    expect(find.textContaining('finish signing in there'), findsNothing);

    await tester.tap(find.text('Log in with Google'));
    await tester.pump();
    expect(
      find.text(
        'Waiting for Log in with Google. If a browser opened, finish signing '
        'in there. The login ends after 10 minutes.',
      ),
      findsOneWidget,
    );

    hold.complete('Logged in via Log in with Google.');
    await tester.pumpAndSettle();
    expect(find.text('Log in to Antigravity'), findsNothing);
  });

  testWidgets('an API-key method asks for the key, keeps it in the vault '
      'under its variable, then authenticates', (tester) async {
    await pump(tester);
    await openLogin(tester);
    await tester.tap(find.text('Use Gemini API key'));
    await tester.pumpAndSettle();
    expect(db.server.agentWork.acpAuthenticates, isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, 'GEMINI_API_KEY'),
      'k-123',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();
    expect(db.server.envVault.values, {'GEMINI_API_KEY': 'k-123'});
    expect(db.server.agentWork.acpAuthenticates, [('ag1', 'gemini-api-key')]);
    expect(find.text('Logged in via Use Gemini API key'), findsOneWidget);
  });

  testWidgets('a terminal method opens a terminal and is not said as logged '
      'in, since the agent cannot confirm it', (tester) async {
    await pump(tester);
    await openLogin(tester);
    await tester.tap(find.text('Log in in a terminal'));
    await tester.pumpAndSettle();
    expect(db.server.agentWork.acpTerminalLogins, [('ag1', 'login')]);
    expect(db.server.agentWork.acpAuthenticates, isEmpty);
    expect(find.textContaining('Logged in via'), findsNothing);
    expect(find.textContaining('finished in a terminal'), findsOneWidget);
  });

  testWidgets('a refused login is shown in the agent\'s words and the '
      'dialog stays open', (tester) async {
    db.server.agentWork.acpAuthRefusal = const DataRefused(
      DataRefusalCode.failed,
      'Antigravity refused Log in with Google: not allowed',
    );
    await pump(tester);
    await openLogin(tester);
    await tester.tap(find.text('Log in with Google'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not allowed'), findsOneWidget);
    expect(find.text('Log in to Antigravity'), findsOneWidget);
  });

  testWidgets('Switch method reopens the list; Forget clears the choice and '
      'asks for a logout', (tester) async {
    db.server.agentWork.acpAuthStates['ag1'] = AcpAuthState(
      installationId: 'ag1',
      methodId: 'oauth-personal',
      methodName: 'Log in with Google',
      chosenAt: DateTime.utc(2026, 10, 2),
      authenticatedAt: DateTime.utc(2026, 10, 2),
    );
    await pump(tester);
    expect(find.text('Logged in via Log in with Google'), findsOneWidget);

    await openLogin(tester, label: 'Switch method…');
    expect(find.text('Log in with Google (now)'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget').last);
    await tester.pumpAndSettle();
    expect(db.server.agentWork.acpClears, [('ag1', true)]);
    expect(find.text('Not logged in through Karmashala'), findsOneWidget);
  });
}

/// A login that answers only once a test lets it.
class _HeldLogin extends AcpLoginActions {
  _HeldLogin(super.ref, this._answer);

  final Future<String> _answer;

  @override
  Future<String> logIn(
    String installationId,
    AcpAuthMethod method, {
    String? apiKey,
  }) => _answer;
}
