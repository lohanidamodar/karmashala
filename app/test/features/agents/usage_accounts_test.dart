import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/usage_accounts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

final t0 = DateTime.utc(2026, 9, 28, 8);

AccountUsageState state(
  String agentId,
  String environmentId, {
  String? email,
  double? percent,
  DateTime? at,
  bool read = true,
}) => AccountUsageState(
  accountKey: '$agentId@$environmentId',
  agentId: agentId,
  environmentId: environmentId,
  usage: !read
      ? null
      : AgentUsage(
          windows: [
            UsageWindow(
              label: '5-hour',
              percent: percent,
              span: const Duration(hours: 5),
            ),
          ],
          fetchedAt: at ?? t0,
          email: email,
        ),
);

void main() {
  test('one account signed in from two environments is one entry, told by '
      'its latest reading, naming both environments', () {
    final accounts = usageAccountsOf([
      state('codex', 'win', email: 'me@x.io', percent: 30, at: t0),
      state(
        'codex',
        'wsl:arch',
        email: 'me@x.io',
        percent: 31,
        at: t0.add(const Duration(minutes: 1)),
      ),
    ]);

    expect(accounts, hasLength(1));
    final codex = accounts.single;
    expect(codex.agentId, 'codex');
    expect(codex.email, 'me@x.io');
    expect(codex.latest.accountKey, 'codex@wsl:arch');
    expect(codex.environmentIds, ['wsl:arch', 'win']);
    expect(codex.accountKeys, {'codex@wsl:arch', 'codex@win'});
  });

  test('the same agent under two emails is two accounts, and so is one whose '
      'email is unknown', () {
    final accounts = usageAccountsOf([
      state('claude', 'win', email: 'a@x.io', percent: 10),
      state('claude', 'wsl:arch', email: 'b@x.io', percent: 20),
      state('claude', 'wsl:other', percent: 5),
    ]);
    expect(accounts, hasLength(3));
  });

  test('two readings with no email are never merged: nothing says they are one '
      'account', () {
    final accounts = usageAccountsOf([
      state('codex', 'win', percent: 10),
      state('codex', 'wsl:arch', percent: 20),
    ]);
    expect(accounts, hasLength(2));
  });

  test('ordered most constrained first; an account with no number is last', () {
    final accounts = usageAccountsOf([
      state('a', 'win', email: 'a@x.io', percent: 10),
      state('b', 'win', email: 'b@x.io'),
      state('c', 'win', email: 'c@x.io', percent: 90),
      state('d', 'win', email: 'd@x.io', percent: 50),
    ]);
    expect([for (final a in accounts) a.agentId], ['c', 'd', 'a', 'b']);
  });

  test('an account the server has not tried yet is not shown, and one it '
      'failed to read is', () {
    final accounts = usageAccountsOf([
      state('a', 'win', read: false),
      state('b', 'win', email: 'b@x.io', percent: 1),
      AccountUsageState(
        accountKey: 'c@win',
        agentId: 'c',
        environmentId: 'win',
        failure: const UsageFailure(
          message: 'Access token expired.',
          kind: UsageFailureKind.auth,
        ),
      ),
    ]);
    expect([for (final a in accounts) a.agentId], ['b', 'c']);
  });

  test('grouped by agent: one account on three machines is one row naming '
      'them, and the most constrained agent leads', () {
    final groups = usageAccountGroupsOf(
      usageAccountsOf([
        state('codex', 'win', email: 'dev@example.com', percent: 40),
        state('claude', 'win', email: 'owner@example.com', percent: 90),
        state(
          'claude',
          'wsl:arch',
          email: 'Owner@Example.com',
          percent: 91,
          at: t0.add(const Duration(minutes: 1)),
        ),
        state('claude', 'ssh:box', email: 'owner@example.com', percent: 89),
        state('claude', 'win', email: 'work@example.org', percent: 10),
        state('antigravity', 'wsl:arch', email: 'dev@example.com'),
      ]),
    );

    expect(
      [for (final g in groups) g.agentId],
      ['claude', 'codex', 'antigravity'],
    );
    final claude = groups.first.accounts;
    expect(claude, hasLength(2));
    expect(
      claude.first.environmentIds,
      unorderedEquals(['win', 'wsl:arch', 'ssh:box']),
    );
    expect(claude.first.tightestPercent, 91);
    expect(claude.last.email, 'work@example.org');
    // Antigravity reads no percentage: an account with nothing to measure.
    expect(groups.last.accounts.single.tightestPercent, isNull);
  });
}
