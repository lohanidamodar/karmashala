import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/app/widgets/desktop_menu.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/application/claude_accounts_controller.dart';
import 'package:karmashala/src/features/agents/domain/agent_installation.dart';
import 'package:karmashala/src/features/agents/domain/claude_account.dart';
import 'package:karmashala/src/features/agents/domain/claude_auth_snapshot.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/presentation/claude_accounts_section.dart';

import '../../support/fixtures.dart';

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
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final installation = agentInstallation();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
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
