import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart';
import '../../../core/util/clock_provider.dart';
import '../../settings/presentation/settings_nav.dart';
import '../application/agent_usage_providers.dart';
import '../application/usage_accounts.dart';
import 'agent_logo.dart';
import 'usage_chip.dart';
import 'usage_chip_popover.dart';

/// The most one account's chip takes in the toolbar, its logo and both
/// windows included; a longer label gives up its tail.
const double kToolbarUsageChipWidth = 150;

/// The `+N` chip the accounts that do not fit fold into.
const double kToolbarUsageMoreWidth = 44;

/// How many of [count] chips fit in [width], leaving room for the `+N` chip
/// when not all of them do.
int toolbarUsageChipsThatFit(double width, int count) {
  if (count * kToolbarUsageChipWidth <= width) return count;
  final room = width - kToolbarUsageMoreWidth;
  if (room <= 0) return 0;
  return (room / kToolbarUsageChipWidth).floor().clamp(0, count);
}

/// **Every signed-in agent account and how much of its limits is spent**, in
/// the toolbar: usage belongs to an account, so it is shown once per account
/// rather than under each session. Most constrained first; what does not fit
/// folds into `+N`. Each opens its detail on click.
class ToolbarUsageStrip extends ConsumerWidget {
  const ToolbarUsageStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(usageAccountsProvider);
    if (accounts.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final shown = toolbarUsageChipsThatFit(
          constraints.maxWidth,
          accounts.length,
        );
        final rest = accounts.sublist(shown);
        return Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final account in accounts.take(shown))
                _AccountChip(account: account),
              if (rest.isNotEmpty) _MoreChip(accounts: rest),
            ],
          ),
        );
      },
    );
  }
}

/// The chip's words for [account]'s latest reading, as the session chip said
/// them: the short and long window, the worst one's colour.
UsageChipView _viewOf(UsageAccount account, DateTime now) {
  final state = account.latest;
  final failure = state.failure;
  final AsyncValue<AgentUsage> value = failure != null
      ? AsyncError(failure.toException(now), StackTrace.empty)
      : state.usage == null
      ? const AsyncLoading()
      : AsyncData(state.usage!);
  return usageChipViewFor(value, now, remembered: state.usage);
}

Color _toneColor(BuildContext context, UsageTone tone) {
  final semantic = SemanticColors.of(context);
  return switch (tone) {
    UsageTone.healthy => semantic.idle,
    UsageTone.warning => semantic.attention,
    UsageTone.critical => semantic.failure,
    UsageTone.muted => semantic.neutral,
  };
}

/// The agent's name as short as a toolbar can carry it: its first word.
String _shortName(String agentId) =>
    AgentRegistry.builtIn.displayNameFor(agentId).split(' ').first;

/// The card a chip opens: every window of the account, its history and notes,
/// with a refresh and the way to the full usage page.
Widget _accountCard(
  BuildContext context,
  WidgetRef ref,
  UsageAccount account,
  UsageChipView view, {
  VoidCallback? onLeave,
}) {
  return UsageChipPopover(
    view: view,
    accountKey: account.latest.accountKey,
    agentId: account.agentId,
    environmentId: account.latest.environmentId,
    environmentIds: account.environmentIds,
    // Each button gives up its tail rather than the card its edge: a large text
    // size must not push either out of a 300px card.
    footer: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: _RefreshButton(accountKeys: account.accountKeys)),
        Flexible(
          child: TextButton(
            onPressed: () {
              onLeave?.call();
              openSettingsTab(ref, anchor: SettingsAnchor.usage);
            },
            child: const Text(
              'Usage settings',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The card's refresh: asks the server to read each of the account's
/// environments now and waits for the answer — a spinner while it asks, and
/// the server's words when it could not read. Firing the ask and forgetting
/// it left a card that looked unchanged whether the read worked, failed or
/// was answered from the throttle's memory.
class _RefreshButton extends ConsumerStatefulWidget {
  const _RefreshButton({required this.accountKeys});

  final Set<String> accountKeys;

  @override
  ConsumerState<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends ConsumerState<_RefreshButton> {
  bool _loading = false;
  String? _failure;

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final readings = ref.read(usageReadingsProvider);
    final failures = <String>[];
    await Future.wait([
      for (final key in widget.accountKeys)
        readings.refresh(key).catchError((Object e) {
          failures.add(e is UsageException ? e.message : '$e');
        }),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failure = failures.isEmpty ? null : failures.toSet().join('\n');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: Insets.md),
        child: InlineSpinner(semanticsLabel: 'Checking usage'),
      );
    }
    final failure = _failure;
    final button = TextButton.icon(
      onPressed: _refresh,
      icon: Icon(
        failure == null ? AppIcons.arrowsClockwise : AppIcons.warning,
        size: Chrome.iconAction,
        color: failure == null ? null : SemanticColors.of(context).failure,
      ),
      label: const Text('Refresh', overflow: TextOverflow.ellipsis),
    );
    return failure == null ? button : Tooltip(message: failure, child: button);
  }
}

MenuStyle _cardStyle() => const MenuStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  backgroundColor: WidgetStatePropertyAll(Colors.transparent),
  shadowColor: WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
  elevation: WidgetStatePropertyAll(0),
);

class _AccountChip extends ConsumerStatefulWidget {
  const _AccountChip({required this.account});

  final UsageAccount account;

  @override
  ConsumerState<_AccountChip> createState() => _AccountChipState();
}

class _AccountChipState extends ConsumerState<_AccountChip> {
  // Kept across rebuilds: a reading landing while the card is open must not
  // close it.
  final controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final now = ref.watch(clockProvider).nowUtc();
    final view = _viewOf(account, now);
    final colour = _toneColor(context, view.tone);
    final theme = Theme.of(context);
    final name = _shortName(account.agentId);

    return MenuAnchor(
      controller: controller,
      style: _cardStyle(),
      menuChildren: [
        _accountCard(context, ref, account, view, onLeave: controller.close),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kToolbarUsageChipWidth),
        child: Semantics(
          button: true,
          label: '$name usage: ${view.tooltip}',
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('toolbar-usage-${account.latest.accountKey}'),
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The agent's mark, not its name: the name is in the
                  // semantics and the card, and the toolbar needs the room.
                  AgentLogo(
                    agentId: account.agentId,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs),
                  Icon(
                    switch (view.mark) {
                      UsageMark.live => AppIcons.circleHalf,
                      UsageMark.stale => AppIcons.clockCounterClockwise,
                      UsageMark.unknown => AppIcons.question,
                    },
                    size: 12,
                    color: colour,
                  ),
                  const SizedBox(width: Insets.xs),
                  Flexible(child: _words(context, view.label, colour)),
                  if (view.longLabel case final longer?) ...[
                    const SizedBox(width: Insets.sm),
                    Flexible(child: _words(context, longer, colour)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _words(BuildContext context, String fact, Color colour) => Text(
    fact,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colour),
  );
}

class _MoreChip extends ConsumerStatefulWidget {
  const _MoreChip({required this.accounts});

  final List<UsageAccount> accounts;

  @override
  ConsumerState<_MoreChip> createState() => _MoreChipState();
}

class _MoreChipState extends ConsumerState<_MoreChip> {
  final controller = MenuController();

  static int _loudness(UsageTone tone) => switch (tone) {
    UsageTone.critical => 3,
    UsageTone.warning => 2,
    UsageTone.healthy => 1,
    UsageTone.muted => 0,
  };

  @override
  Widget build(BuildContext context) {
    final accounts = widget.accounts;
    final now = ref.watch(clockProvider).nowUtc();
    final worst = accounts
        .map((a) => _viewOf(a, now).tone)
        .reduce((a, b) => _loudness(a) >= _loudness(b) ? a : b);
    final maxHeight = MediaQuery.sizeOf(context).height - Insets.xl * 4;
    return MenuAnchor(
      controller: controller,
      style: _cardStyle(),
      menuChildren: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maxHeight < 160 ? 160 : maxHeight,
          ),
          // Not primary: the menu's own panel already holds the primary
          // scroll controller.
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final account in accounts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Insets.xs),
                    child: _accountCard(
                      context,
                      ref,
                      account,
                      _viewOf(account, now),
                      onLeave: controller.close,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      child: SizedBox(
        width: kToolbarUsageMoreWidth,
        child: InkWell(
          key: const ValueKey('toolbar-usage-more'),
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Center(
            child: Text(
              '+${accounts.length}',
              semanticsLabel: '${accounts.length} more accounts',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: _toneColor(context, worst),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
