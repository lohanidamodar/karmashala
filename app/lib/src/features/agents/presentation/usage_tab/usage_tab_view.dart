import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../core/util/clock_provider.dart';
import '../../../environments/application/environments_controller.dart';
import '../../../sessions/data/server_session_stats.dart';
import '../../application/session_token_totals.dart' show formatTokenCount;
import '../../application/usage_accounts.dart';
import '../../application/usage_history.dart';
import '../../application/usage_session_tokens.dart';
import '../agent_logo.dart';
import '../usage_chip.dart' show formatUsageDuration;
import 'usage_breakdown_section.dart';
import 'usage_tab_state.dart';
import 'usage_windows_section.dart';

/// The widest the page's content runs: past it, charts stretch into lines too
/// long to read and rows drift apart from their numbers.
const double kUsageTabContentMaxWidth = 960;

/// **The Usage tab** (spec §5, Ctrl+Shift+U): pick an account and a range;
/// see its tokens, sessions, tightest window and limits hit; each window over
/// time with its run-out forecast; where the tokens went by project and
/// model; and the heaviest sessions, each a click from opening.
///
/// Built only while its tab is on screen (see `_buildPane`). Measures its own
/// width once at the top — it is a pane, never under intrinsics — and lays
/// everything out in one scroll view, so it reads from a 360px split up.
class UsageTabView extends ConsumerWidget {
  const UsageTabView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Under a page that already names it (the phone's More), no second title.
    final untitled = PaneTitleOverride.maybeOf(context) != null;
    return Scaffold(
      appBar: untitled
          ? null
          : AppBar(
              // A page header, as Settings has: `Chrome.titleBar` is 30px.
              toolbarHeight: 44,
              // A workbench tab: an implied back button would pop the app's
              // route.
              automaticallyImplyLeading: false,
              title: Row(
                children: [
                  Icon(AppIcons.chartBar, color: theme.colorScheme.tertiary),
                  const SizedBox(width: Insets.sm),
                  const Flexible(
                    child: Text(
                      'Usage',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final gutter = constraints.maxWidth < 560 ? Insets.lg : Insets.xl;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(gutter, Insets.lg, gutter, Insets.xl),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kUsageTabContentMaxWidth,
                ),
                child: const _UsagePage(),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UsagePage extends ConsumerWidget {
  const _UsagePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final accounts = ref.watch(usageAccountsProvider);
    if (accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: Insets.xl),
        child: Text(
          'No account has a usage reading yet. Usage appears here once an '
          'agent is signed in and its limits have been read — open a session '
          'with Claude Code or Codex, or refresh from an account chip in the '
          'title bar.',
          style: muted,
        ),
      );
    }
    final selection = ref.watch(usageTabSelectionProvider);
    final account = accounts.firstWhere(
      (a) => usageAccountId(a) == selection.accountId,
      // The tightest, which the list already puts first.
      orElse: () => accounts.first,
    );
    final range = selection.range;
    final now = ref.watch(clockProvider).nowUtc();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Pickers(accounts: accounts, account: account, range: range),
        const SizedBox(height: Insets.lg),
        _AccountBody(account: account, range: range, now: now),
      ],
    );
  }
}

/// The account and range pickers, as pills: every choice in view, and they
/// wrap onto a second line in a narrow pane instead of hiding in a menu.
class _Pickers extends ConsumerWidget {
  const _Pickers({
    required this.accounts,
    required this.account,
    required this.range,
  });

  final List<UsageAccount> accounts;
  final UsageAccount account;
  final UsageRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selection = ref.read(usageTabSelectionProvider.notifier);
    final chosen = usageAccountId(account);
    return Wrap(
      spacing: Insets.xl,
      runSpacing: Insets.md,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Account'),
            const SizedBox(height: Insets.xs),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                for (final a in accounts)
                  ChoiceChip(
                    avatar: AgentLogo(
                      agentId: a.agentId,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    label: _AccountLabel(account: a),
                    selected: usageAccountId(a) == chosen,
                    onSelected: (_) =>
                        selection.selectAccount(usageAccountId(a)),
                  ),
              ],
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Range'),
            const SizedBox(height: Insets.xs),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                for (final r in UsageRange.values)
                  ChoiceChip(
                    label: Text(r.label),
                    selected: r == range,
                    onSelected: (_) => selection.selectRange(r),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// `Claude · me@example.com`, or the machines it is read from when the
/// reading named no email.
class _AccountLabel extends ConsumerWidget {
  const _AccountLabel({required this.account});

  final UsageAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final who =
        account.email ??
        [
          for (final id in account.environmentIds)
            ref.watch(environmentLabelForIdProvider(id)),
        ].join(', ');
    return ConstrainedBox(
      // An email longer than a phone is wide ellipsises rather than pushing
      // the pill off the page.
      constraints: const BoxConstraints(maxWidth: 260),
      child: Text(
        '${usageAgentName(account.agentId).split(' ').first} · $who',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Everything about the chosen account over the chosen range.
class _AccountBody extends ConsumerWidget {
  const _AccountBody({
    required this.account,
    required this.range,
    required this.now,
  });

  final UsageAccount account;
  final UsageRange range;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final usage = account.latest.usage;
    final since = now.subtract(range.span);

    // Asked of the server, from the minute — a ticking clock must not mint a
    // new query per build. The last answer stays while a newer one comes.
    final minute = DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    );
    final historyValue = ref.watch(
      usageHistoryProvider((
        account: account.latest.accountKey,
        from: minute.subtract(range.span),
      )),
    );
    final history = historyValue.value;
    final inRange = [
      for (final s in history ?? const <UsageSample>[])
        if (!s.recordedAt.isBefore(since)) s,
    ];

    final rows = ref.watch(usageSessionRowsProvider);
    final breakdown = switch (rows) {
      AsyncValue(:final value?) => usageBreakdownOf(
        value,
        since: since,
        agentId: account.agentId,
      ),
      _ => null,
    };
    final agent = usageAgentName(account.agentId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatTileGrid(
          tiles: [
            _tokensTile(rows, breakdown, agent),
            _sessionsTile(rows, breakdown),
            _tightestTile(usage),
            _limitsTile(historyValue, inRange),
          ],
        ),
        const SizedBox(height: Insets.xl),
        const EyebrowLabel('Windows over time'),
        const SizedBox(height: Insets.sm),
        if (usage == null)
          Text(
            account.latest.failure?.toException(now).message ??
                'This account has not been read yet.',
            style: muted,
          )
        else
          UsageWindowsOverTime(
            usage: usage,
            history: history ?? const [],
            range: range,
            now: now,
          ),
        const SizedBox(height: Insets.xl),
        Row(
          children: [
            const Expanded(child: EyebrowLabel('Where it went')),
            if (rows.isLoading)
              const InlineSpinner(semanticsLabel: 'Counting tokens')
            else
              TextButton.icon(
                onPressed: () {
                  ref.read(serverSessionStatsProvider).forget();
                  ref.invalidate(usageSessionRowsProvider);
                },
                icon: const Icon(
                  AppIcons.arrowsClockwise,
                  size: Chrome.iconAction,
                ),
                label: const Text('Count again'),
              ),
          ],
        ),
        Text(
          'Whole-session totals, cache reads included, of $agent sessions last '
          'active in ${range.phrase}. A session does not record which account '
          'ran it, so this counts every $agent account on this workspace.',
          style: muted,
        ),
        const SizedBox(height: Insets.sm),
        ..._breakdownBody(context, rows, breakdown, muted),
      ],
    );
  }

  List<Widget> _breakdownBody(
    BuildContext context,
    AsyncValue<List<UsageSessionRow>> rows,
    UsageBreakdown? breakdown,
    TextStyle? muted,
  ) {
    if (rows.hasError && breakdown == null) {
      return [Text('Could not count tokens: ${rows.error}', style: muted)];
    }
    if (breakdown == null) {
      return [Text('Reading each recent session’s own file…', style: muted)];
    }
    if (breakdown.isEmpty) {
      return [
        Text(
          breakdown.uncounted == 0
              ? 'Not recorded — no session was active in ${range.phrase}.'
              : 'Not recorded — no session active in ${range.phrase} wrote '
                    'token counts to its file.',
          style: muted,
        ),
      ];
    }
    return [
      UsageWhereItWent(breakdown: breakdown),
      const SizedBox(height: Insets.xl),
      const EyebrowLabel('Heaviest sessions'),
      const SizedBox(height: Insets.xs),
      UsageHeaviestSessions(sessions: breakdown.heaviest, now: now),
    ];
  }

  Widget _tokensTile(
    AsyncValue<List<UsageSessionRow>> rows,
    UsageBreakdown? breakdown,
    String agent,
  ) {
    final counted = breakdown != null && !breakdown.isEmpty;
    return StatTile(
      label: 'Tokens',
      value: counted ? formatTokenCount(breakdown.total) : null,
      unrecorded: breakdown == null && rows.isLoading
          ? 'counting…'
          : 'not recorded',
      caption: counted
          ? '${breakdown.counted} '
                '${breakdown.counted == 1 ? 'session' : 'sessions'}'
          : null,
      tooltip:
          'Whole-session totals of $agent sessions last active in '
          '${range.phrase}, from each session’s own file.',
    );
  }

  Widget _sessionsTile(
    AsyncValue<List<UsageSessionRow>> rows,
    UsageBreakdown? breakdown,
  ) {
    final uncounted = breakdown?.uncounted ?? 0;
    return StatTile(
      label: 'Sessions',
      value: breakdown == null || breakdown.active == 0
          ? null
          : '${breakdown.active}',
      unrecorded: breakdown == null && rows.isLoading
          ? 'counting…'
          : 'not recorded',
      caption: uncounted == 0 ? null : '$uncounted recorded no counts',
      tooltip:
          'Sessions whose own file shows activity in ${range.phrase}. One '
          'whose last activity is unknown is not placed in any range.',
    );
  }

  Widget _tightestTile(AgentUsage? usage) {
    UsageWindow? tightest;
    for (final window in usage?.windows ?? const <UsageWindow>[]) {
      final percent = window.percent;
      if (percent == null) continue;
      if (tightest == null || percent > tightest.percent!) tightest = window;
    }
    final reset = tightest?.resetsAt;
    return StatTile(
      label: 'Tightest window',
      value: tightest == null ? null : '${tightest.percent!.round()}%',
      caption: tightest == null
          ? null
          : reset == null
          ? tightest.label
          : '${tightest.label} · resets in '
                '${formatUsageDuration(reset.difference(now))}',
      tooltip: 'The window nearest its limit in the newest reading.',
    );
  }

  Widget _limitsTile(
    AsyncValue<List<UsageSample>> history,
    List<UsageSample> inRange,
  ) {
    final loading = history.value == null && history.isLoading;
    return StatTile(
      label: 'Limits hit',
      value: inRange.isEmpty ? null : '${usageLimitsHit(inRange)}',
      unrecorded: loading ? 'reading…' : 'not recorded',
      caption: inRange.isEmpty ? null : 'in recorded readings',
      tooltip:
          'Times a window reached 100% in the readings kept for '
          '${range.phrase}. A limit reached and reset between two readings '
          'is not seen.',
    );
  }
}
