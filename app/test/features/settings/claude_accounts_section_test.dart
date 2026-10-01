import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/claude_accounts_controller.dart';
import 'package:karmashala/src/features/agents/application/codex_accounts_controller.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala/src/features/settings/presentation/claude_accounts_section.dart';
import 'package:karmashala/src/features/settings/presentation/codex_accounts_section.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// The "Switch to" menu over the shared pool of saved Claude accounts.
///
/// It listed each email as a bare `PopupMenuItem` with a tick pinned to the far
/// right of the active one — Material's 48px row with no leading glyph, in a
/// settings page whose other menus are the house 32px row.
void main() {
  ClaudeAccount account(String email) => ClaudeAccount(
    id: email,
    email: email,
    claudeAiOauth: const {},
    capturedAt: testTime,
  );

  final mine = account('me@example.com');
  final theirs = account('other@example.com');

  /// Records the switch instead of writing anyone's credentials to disk.
  final switched = <ClaudeAccount>[];

  Future<void> pump(WidgetTester tester) async {
    switched.clear();
    final db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(windowsEnv());
    final installation = agentInstallation();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          claudeAccountsControllerProvider.overrideWith(
            () => _FakeAccounts([mine, theirs], switched),
          ),
          claudeAuthSnapshotProvider(installation).overrideWith(
            (ref) async =>
                ClaudeAuthSnapshot(environmentId: 'windows', email: mine.email),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ClaudeAccountsSection(installations: [installation]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the account pool is a menu of house rows', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Switch to'));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopMenuItem<ClaudeAccount>), findsNWidgets(2));
    expect(
      tester.getSize(find.byType(DesktopMenuItem<ClaudeAccount>).first).height,
      Chrome.menuRow,
    );
    // The account already in force is the checked one, and cannot be re-picked.
    expect(
      find.descendant(
        of: find.byType(DesktopMenuItem<ClaudeAccount>),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
    final rows = tester.widgetList<DesktopMenuItem<ClaudeAccount>>(
      find.byType(DesktopMenuItem<ClaudeAccount>),
    );
    expect(rows.firstWhere((r) => r.value == mine).enabled, isFalse);
    expect(rows.firstWhere((r) => r.value == theirs).enabled, isTrue);
  });

  testWidgets('picking another account still switches to it', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Switch to'));
    await tester.pumpAndSettle();
    // The pool below the card lists the same emails; this is the menu's row.
    await tester.tap(
      find.descendant(
        of: find.byType(DesktopMenuItem<ClaudeAccount>),
        matching: find.text(theirs.email),
      ),
    );
    await tester.pumpAndSettle();

    expect(switched, [theirs]);
  });

  group('a token expiry is read against the app clock', () {
    // `testTime` is long past, so a section that asked the wall clock would
    // call a token three hours ahead of it "expired".
    final expiresAt = testTime.add(const Duration(hours: 3, minutes: 5));

    testWidgets('Claude', (tester) async {
      final db = TestMachine();
      FakeDataServer().runsOn(db);
      db.server.environmentRows.upsert(windowsEnv());
      final installation = agentInstallation();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            await db.server.override(),
            clockProvider.overrideWithValue(FixedClock(testTime)),
            claudeAccountsControllerProvider.overrideWith(
              () => _FakeAccounts(const [], []),
            ),
            claudeAuthSnapshotProvider(installation).overrideWith(
              (ref) async => ClaudeAuthSnapshot(
                environmentId: 'windows',
                email: 'me@example.com',
                subscriptionType: 'max',
                accessTokenExpiresAt: expiresAt,
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ClaudeAccountsSection(installations: [installation]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('max · token expires in 3h'), findsOneWidget);
    });

    testWidgets('Codex', (tester) async {
      final db = TestMachine();
      FakeDataServer().runsOn(db);
      db.server.environmentRows.upsert(windowsEnv());
      final installation = agentInstallation();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            await db.server.override(),
            clockProvider.overrideWithValue(FixedClock(testTime)),
            codexAccountsControllerProvider.overrideWith(
              () => _FakeCodexAccounts(const []),
            ),
            codexAuthSnapshotProvider(installation).overrideWith(
              (ref) async => CodexAuthSnapshot(
                environmentId: 'windows',
                accountId: 'account-1',
                planType: 'pro',
                accessTokenExpiresAt: expiresAt,
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CodexAccountsSection(installations: [installation]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('pro · token expires in 3h'), findsOneWidget);
    });
  });

  testWidgets('Codex shows the active identity and captured accounts', (
    tester,
  ) async {
    final db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(windowsEnv());
    final installation = agentInstallation();
    final captured = CodexAccount(
      id: 'saved-1',
      accountId: 'account-1',
      email: 'owner@example.com',
      planType: 'pro',
      auth: const {},
      capturedAt: testTime,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          codexAccountsControllerProvider.overrideWith(
            () => _FakeCodexAccounts([captured]),
          ),
          codexAuthSnapshotProvider(installation).overrideWith(
            (ref) async => const CodexAuthSnapshot(
              environmentId: 'windows',
              accountId: 'account-1',
              email: 'owner@example.com',
              planType: 'pro',
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CodexAccountsSection(installations: [installation]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(SettingsAnchor.codexAccounts.heading), findsOneWidget);
    expect(find.text('owner@example.com'), findsNWidgets(2));
    expect(find.text('pro'), findsNWidgets(2));
    expect(find.text('Capture current'), findsOneWidget);
    expect(find.text('Switch to'), findsOneWidget);
    expect(find.byTooltip('Forget this captured account'), findsOneWidget);
  });
}

class _FakeAccounts extends ClaudeAccountsController {
  _FakeAccounts(this._accounts, this._switched);

  final List<ClaudeAccount> _accounts;
  final List<ClaudeAccount> _switched;

  @override
  List<ClaudeAccount> build() => _accounts;

  @override
  Future<void> switchTo(
    AgentInstallation installation,
    ClaudeAccount account,
  ) async => _switched.add(account);
}

class _FakeCodexAccounts extends CodexAccountsController {
  _FakeCodexAccounts(this._accounts);

  final List<CodexAccount> _accounts;

  @override
  List<CodexAccount> build() => _accounts;
}
