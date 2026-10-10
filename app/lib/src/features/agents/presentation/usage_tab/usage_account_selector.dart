import 'package:agent_cli/usage.dart' show usageSeverityFor;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../app/widgets/adaptive_modal.dart';
import '../../../../app/widgets/fact_list.dart' show FactListHeader;
import '../../../environments/application/environments_controller.dart';
import '../../application/usage_accounts.dart';
import '../../application/usage_session_tokens.dart' show usageAgentName;
import '../agent_logo.dart';
import '../usage_window_meter.dart' show usageSeverityColor;
import 'usage_tab_state.dart';

/// "Claude", from "Claude Code".
String usageAgentShortName(String agentId) =>
    usageAgentName(agentId).split(' ').first;

/// **The Usage tab's account selector** (round 86): one row saying what the
/// page shows — every account, or one — that opens [UsageAccountList] as a
/// sheet on a phone and a popover on a desktop. One component everywhere, in
/// place of a wall of chips.
class UsageAccountPicker extends ConsumerWidget {
  const UsageAccountPicker({
    required this.accounts,
    required this.selected,
    super.key,
  });

  final List<UsageAccount> accounts;

  /// Null when the page shows every account.
  final UsageAccount? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final account = selected;
    final agents = {for (final a in accounts) a.agentId}.length;
    final title = account == null
        ? 'All accounts'
        : '${usageAgentShortName(account.agentId)} · '
              '${usageAccountName(ref, account)}';
    final detail = account == null
        ? '${accounts.length} accounts · $agents '
              '${agents == 1 ? 'agent' : 'agents'}'
        : account.email == null
        ? null
        : usageAccountMachines(ref, account);
    return Semantics(
      button: true,
      label: 'Account: $title. Change',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('usage-account-picker'),
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: () => _open(context, ref),
          child: Container(
            constraints: BoxConstraints(
              minHeight: UiDensity.of(context).isTouch
                  ? Touch.target
                  : Chrome.menuRow,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.xs,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                _Glyph(agentId: account?.agentId),
                const SizedBox(width: _glyphGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                    ],
                  ),
                ),
                if (account != null) ...[
                  const SizedBox(width: Insets.md),
                  UsageAccountFigure(account: account),
                ],
                const SizedBox(width: Insets.sm),
                Icon(
                  AppIcons.caretDown,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) =>
      showAdaptivePopover<void>(
        context: context,
        title: 'Accounts',
        builder: (sheet) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          child: UsageAccountList(
            accounts: accounts,
            selectedId: selected == null ? null : usageAccountId(selected!),
            onSelected: (id) {
              final selection = ref.read(usageTabSelectionProvider.notifier);
              id == null ? selection.selectAll() : selection.selectAccount(id);
              Navigator.of(sheet).pop();
            },
          ),
        ),
      );
}

/// **Every account, grouped by agent**: "All accounts" first when
/// [showAll], then under each agent's name a row per account — its sign-in,
/// the machines it is read on, and its tightest window as a bar and a
/// percentage, or "not measured" for an agent that reports none.
class UsageAccountList extends StatelessWidget {
  const UsageAccountList({
    required this.accounts,
    required this.selectedId,
    required this.onSelected,
    this.showAll = true,
    super.key,
  });

  final List<UsageAccount> accounts;

  /// [usageAccountId] of the chosen account; null for every account.
  final String? selectedId;

  /// Called with an account's [usageAccountId], or null for every account.
  final ValueChanged<String?> onSelected;
  final bool showAll;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (showAll)
        UsageAccountRow.all(
          count: accounts.length,
          selected: selectedId == null,
          onTap: () => onSelected(null),
        ),
      for (final group in usageAccountGroupsOf(accounts)) ...[
        FactListHeader(usageAgentName(group.agentId)),
        for (final account in group.accounts)
          UsageAccountRow(
            account: account,
            selected: usageAccountId(account) == selectedId,
            onTap: () => onSelected(usageAccountId(account)),
          ),
      ],
    ],
  );
}

/// One row of [UsageAccountList], drawn to [FactRow]'s measure — its
/// padding, glyph column, text and height — so every row is as wide as the
/// list and their figures line up.
class UsageAccountRow extends ConsumerWidget {
  const UsageAccountRow({
    required UsageAccount this.account,
    required this.selected,
    required this.onTap,
    super.key,
  }) : count = 0;

  const UsageAccountRow.all({
    required this.count,
    required this.selected,
    required this.onTap,
    super.key,
  }) : account = null;

  /// Null for the "All accounts" row.
  final UsageAccount? account;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final account = this.account;
    final name = account == null
        ? 'All accounts'
        : usageAccountName(ref, account);
    final detail = account == null
        ? '$count accounts'
        : account.email == null
        ? null
        : usageAccountMachines(ref, account);
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          key: ValueKey(
            account == null
                ? 'usage-account-all'
                : 'usage-account-${usageAccountId(account)}',
          ),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.xs,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    (UiDensity.of(context).isTouch
                        ? Touch.target
                        : Chrome.menuRow) -
                    Insets.xs * 2,
              ),
              child: Row(
                children: [
                  _Glyph(agentId: account?.agentId),
                  const SizedBox(width: _glyphGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: selected ? FontWeight.w600 : null,
                          ),
                        ),
                        if (detail != null)
                          Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (account != null) ...[
                    const SizedBox(width: Insets.md),
                    UsageAccountFigure(account: account),
                  ],
                  const SizedBox(width: Insets.sm),
                  SizedBox(
                    width: Chrome.iconSmall,
                    child: selected
                        ? Icon(
                            AppIcons.check,
                            size: Chrome.iconSmall,
                            color: scheme.primary,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An account's tightest window as a mini bar and its percentage, or "not
/// measured" when its agent reports no percentage (Antigravity) — never an
/// empty bar, which would read as 0%. One width everywhere, so a column of
/// them lines up.
class UsageAccountFigure extends StatelessWidget {
  const UsageAccountFigure({required this.account, super.key});

  final UsageAccount account;

  /// The figure's width at 1x text.
  static const width = 88.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final small = theme.textTheme.labelSmall;
    final percent = account.tightestPercent;
    final Widget figure;
    if (percent == null) {
      figure = Text(
        account.latest.usage == null ? 'not read' : 'not measured',
        key: ValueKey('usage-account-unmeasured-${usageAccountId(account)}'),
        textAlign: TextAlign.end,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: small?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    } else {
      figure = Row(
        children: [
          Expanded(
            child: LinearMeter(
              value: percent / 100,
              thickness: 4,
              color: usageSeverityColor(context, usageSeverityFor(percent)),
              semanticsLabel: 'Tightest window ${percent.round()}%',
            ),
          ),
          const SizedBox(width: Insets.xs),
          SizedBox(
            width: scaler.scale(32),
            child: Text(
              '${percent.round()}%',
              textAlign: TextAlign.end,
              maxLines: 1,
              style: small?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      );
    }
    return SizedBox(width: scaler.scale(width), child: figure);
  }
}

/// Who the account is: its email, or where it is signed in when the reading
/// named no one.
String usageAccountName(WidgetRef ref, UsageAccount account) =>
    account.email ?? 'signed in on ${usageAccountMachines(ref, account)}';

/// The machines [account] is read on: "This PC, WSL · archlinux".
String usageAccountMachines(WidgetRef ref, UsageAccount account) => [
  for (final id in account.environmentIds.toSet())
    ref.watch(environmentLabelForIdProvider(id)),
].join(', ');

const double _glyphGap = Insets.sm + Insets.xxs;

/// An agent's logo in [FactRow]'s glyph column, or the every-account glyph.
class _Glyph extends StatelessWidget {
  const _Glyph({required this.agentId});

  final String? agentId;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final agent = agentId;
    return SizedBox(
      width: Chrome.icon,
      child: Center(
        child: agent == null
            ? Icon(AppIcons.usersThree, size: Chrome.icon, color: color)
            : AgentLogo(agentId: agent, size: Chrome.icon, color: color),
      ),
    );
  }
}
