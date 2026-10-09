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
import '../application/agent_account_switch.dart';
import '../application/agent_usage_providers.dart';
import '../application/usage_accounts.dart';
import '../application/usage_forecast.dart';
import 'agent_logo.dart';
import 'usage_chip.dart';
import 'usage_chip_popover.dart';
import 'usage_tab/usage_tab_state.dart' show usageAccountId;

/// The most one account's chip takes in the toolbar: its mark, the gauge and
/// both numbers.
const double kToolbarUsageChipWidth = 112;

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
UsageChipView _viewOf(WidgetRef ref, UsageAccount account, DateTime now) {
  final state = account.latest;
  final failure = state.failure;
  final AsyncValue<AgentUsage> value = failure != null
      ? AsyncError(failure.toException(now), StackTrace.empty)
      : state.usage == null
      ? const AsyncLoading()
      : AsyncData(state.usage!);
  return usageChipViewFor(
    value,
    now,
    remembered: state.usage,
    forecasts: ref.watch(usageForecastsProvider(state.accountKey)),
  );
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

/// The card a chip opens: the account, its machines and their switchers, every
/// window with its pace, the week with its forecast, and the notes —
/// with a refresh that waits, and the ways to the Usage tab and its settings.
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
    // size must not push any of them out of the fixed-width card.
    footer: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: _RefreshButton(accountKeys: account.accountKeys)),
        // Spec §5's "Usage details": this account in the Usage tab, where its
        // windows have a range and its tokens a breakdown.
        Flexible(
          child: TextButton(
            onPressed: () {
              onLeave?.call();
              openUsageTab(ref, accountId: usageAccountId(account));
            },
            // Short words: three buttons share a 344px card.
            child: const Tooltip(
              message: 'Usage details: this account in the Usage tab',
              child: Text('Details', overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        Flexible(
          child: TextButton(
            onPressed: () {
              onLeave?.call();
              openSettingsTab(ref, anchor: SettingsAnchor.usage);
            },
            child: const Tooltip(
              message: 'Usage settings',
              child: Text('Settings', overflow: TextOverflow.ellipsis),
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

class _AccountChipState extends ConsumerState<_AccountChip>
    with _FollowsSwitches {
  // Kept across rebuilds: a reading landing while the card is open must not
  // close it.
  @override
  final controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final now = ref.watch(clockProvider).nowUtc();
    final view = _viewOf(ref, account, now);
    followSwitches([account]);
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
        // Hovered, the chip says what the click card says in full: each
        // window's share, how long until it resets and the exact time it
        // does, the account and how old the reading is (owner, 2026-10-01).
        // Excluded from semantics: the label below already carries it.
        child: Tooltip(
          message: '$name\n${view.tooltip}',
          excludeFromSemantics: true,
          child: Semantics(
            button: true,
            label: '$name usage: ${view.tooltip}',
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('toolbar-usage-${account.latest.accountKey}'),
              borderRadius: BorderRadius.circular(Radii.sm),
              onTap: () => toggle(),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: Insets.xs,
                ),
                // Spec §4: the agent's mark, the short window's number, the
                // long window's dimmed after it. The resets, the account and
                // the reading's age are in the card a click opens.
                // Shrinks rather than clips at a large text size: the numbers
                // are the chip.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AgentLogo(
                        agentId: account.agentId,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Insets.sm),
                      ..._facts(context, view, colour),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _facts(BuildContext context, UsageChipView view, Color colour) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.labelMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final short = view.short;
    if (short == null) {
      // Nothing measured: a dash that is plainly not a reading, and the
      // glyph that says whether one is on its way.
      return [
        Text('—', style: style?.copyWith(color: muted)),
        if (view.mark != UsageMark.live) ...[
          const SizedBox(width: Insets.xs),
          Icon(AppIcons.question, size: 12, color: muted),
        ],
      ];
    }
    final long = view.long;
    return [
      _UsageGauge(short: short, long: long),
      const SizedBox(width: Insets.xs + 2),
      Text(
        '${short.percent}%',
        style: style?.copyWith(
          fontWeight: FontWeight.w600,
          color: short.tone == UsageTone.healthy
              ? theme.colorScheme.onSurface
              : _toneColor(context, short.tone),
        ),
      ),
      if (long != null) ...[
        const SizedBox(width: Insets.xs + 2),
        Text(
          '${long.percent}%',
          style: style?.copyWith(
            color: long.tone == UsageTone.healthy
                ? muted.withValues(alpha: 0.75)
                : _toneColor(context, long.tone),
          ),
        ),
      ],
      // A number this read did not confirm says so with its glyph; the age is
      // in the card.
      if (view.mark == UsageMark.stale) ...[
        const SizedBox(width: Insets.xs),
        Icon(AppIcons.clockCounterClockwise, size: 11, color: colour),
      ],
    ];
  }
}

/// **Two rings**, the short window outside and the long one inside: how full
/// each is at a glance, before the numbers are read.
class _UsageGauge extends StatelessWidget {
  const _UsageGauge({required this.short, this.long});

  final UsageFact short;
  final UsageFact? long;

  static const _size = 16.0;

  @override
  Widget build(BuildContext context) {
    Color toneOf(UsageFact fact) => fact.tone == UsageTone.healthy
        ? Theme.of(context).colorScheme.primary
        : _toneColor(context, fact.tone);
    final long = this.long;
    return SizedBox.square(
      dimension: _size,
      child: CustomPaint(
        painter: _RingsPainter(
          track: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.22),
          outer: (short.percent / 100, toneOf(short)),
          inner: long == null
              ? null
              : (long.percent / 100, toneOf(long).withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  const _RingsPainter({required this.track, required this.outer, this.inner});

  final Color track;
  final (double, Color) outer;
  final (double, Color)? inner;

  static const _stroke = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    void ring(double radius, (double, Color) fill) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(centre, radius, paint..color = track);
      final share = fill.$1.clamp(0.0, 1.0);
      if (share <= 0) return;
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: radius),
        -1.5707963267948966,
        6.283185307179586 * share,
        false,
        paint..color = fill.$2,
      );
    }

    final radius = size.shortestSide / 2 - _stroke / 2;
    ring(radius, outer);
    if (inner case final inner?) ring(radius - _stroke - 1.5, inner);
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.track != track || old.outer != outer || old.inner != inner;
}

class _MoreChip extends ConsumerStatefulWidget {
  const _MoreChip({required this.accounts});

  final List<UsageAccount> accounts;

  @override
  ConsumerState<_MoreChip> createState() => _MoreChipState();
}

class _MoreChipState extends ConsumerState<_MoreChip> with _FollowsSwitches {
  @override
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
    followSwitches(accounts);
    final worst = accounts
        .map((a) => _viewOf(ref, a, now).tone)
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
                      _viewOf(ref, account, now),
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
          onTap: () => toggle(),
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

/// How long after a switch the card holding the machine opens on its own: a
/// chip built later than this does not open for an old switch.
const Duration _followSwitchFor = Duration(seconds: 10);

/// A chip's card follows an account switch: the switched machine's row moves
/// to the new account's card, so that one opens and the card it left closes,
/// and the outcome is read where the machine is now.
mixin _FollowsSwitches<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  MenuController get controller;

  AccountSwitchOutcome? _followed;

  /// Opening by hand starts afresh: the last switch's words are not repeated.
  void toggle() {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    ref.read(accountSwitchControllerProvider.notifier).dismiss();
    controller.open();
  }

  /// Called from build with the accounts this chip's card shows.
  void followSwitches(List<UsageAccount> mine) {
    final last = ref.watch(accountSwitchControllerProvider).last;
    if (last == null || !last.succeeded || identical(last, _followed)) return;
    final now = ref.read(clockProvider).nowUtc();
    if (now.difference(last.at) > _followSwitchFor) return;
    bool holds(UsageAccount a) =>
        a.agentId == last.agentId &&
        a.environmentIds.contains(last.environmentId);
    final void Function() act;
    if (mine.any(holds)) {
      // Not settled while open: this may be the card the machine is leaving,
      // whose readings have not caught up yet.
      if (controller.isOpen) return;
      act = () {
        if (!controller.isOpen) controller.open();
      };
    } else if (ref.watch(usageAccountsProvider).any(holds)) {
      act = () {
        if (controller.isOpen) controller.close();
      };
    } else {
      // The new account's reading has not arrived yet; look again when it
      // does.
      return;
    }
    _followed = last;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) act();
    });
  }
}
