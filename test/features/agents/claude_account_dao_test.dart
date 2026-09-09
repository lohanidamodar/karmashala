import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/claude_account_dao.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClaudeAccountDao', () {
    late AppDatabase db;
    late ClaudeAccountDao dao;

    setUp(() {
      db = AppDatabase.memory();
      dao = ClaudeAccountDao(db);
    });
    tearDown(() => db.close());

    ClaudeAccount account({
      String id = 'a1',
      String email = 'me@x.com',
      String? org = 'org-1',
      String token = 'tok',
    }) => ClaudeAccount(
      id: id,
      email: email,
      organizationUuid: org,
      organizationName: 'Org',
      subscriptionType: 'max',
      rateLimitTier: 'tier-x',
      claudeAiOauth: {'accessToken': token, 'expiresAt': 123},
      oauthAccount: {'emailAddress': email, 'organizationUuid': org},
      capturedEnvironmentId: 'wsl:archlinux',
      capturedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    test('round-trips an account, including the JSON blobs', () {
      dao.upsert(account());
      final loaded = dao.getAll();
      expect(loaded, hasLength(1));
      final a = loaded.first;
      expect(a.email, 'me@x.com');
      expect(a.organizationUuid, 'org-1');
      expect(a.subscriptionType, 'max');
      expect(a.claudeAiOauth['accessToken'], 'tok');
      expect(a.oauthAccount!['emailAddress'], 'me@x.com');
      expect(a.capturedEnvironmentId, 'wsl:archlinux');
      expect(a.accessTokenExpiresAt, DateTime.fromMillisecondsSinceEpoch(123));
    });

    test('re-capturing the same (email, org) updates in place', () {
      dao.upsert(account(token: 'old'));
      final saved = dao.upsert(account(id: 'a2', token: 'new'));
      final loaded = dao.getAll();
      expect(loaded, hasLength(1));
      expect(saved.id, 'a1');
      expect(loaded.first.claudeAiOauth['accessToken'], 'new');
    });

    test('re-capturing an account without an org updates in place', () {
      dao.upsert(account(org: null, token: 'old'));
      final saved = dao.upsert(account(id: 'a2', org: null, token: 'new'));
      final loaded = dao.getAll();
      expect(loaded, hasLength(1));
      expect(saved.id, 'a1');
      expect(loaded.single.claudeAiOauth['accessToken'], 'new');
    });

    test('same email in different orgs are distinct rows', () {
      dao.upsert(account(id: 'a1', org: 'org-1'));
      dao.upsert(account(id: 'a2', org: 'org-2'));
      expect(dao.getAll(), hasLength(2));
    });

    test('delete removes a saved account', () {
      dao.upsert(account());
      dao.delete('a1');
      expect(dao.getAll(), isEmpty);
    });
  });
}
