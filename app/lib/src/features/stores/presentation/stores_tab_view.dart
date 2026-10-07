import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../app/shell/workbench_tabs.dart' show openSettingsTab;
import '../../../core/util/clock_provider.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../application/store_attention.dart';
import '../application/store_groups.dart';
import '../application/stores_controller.dart';
import 'store_app_card.dart';
import 'store_app_detail.dart';
import 'stores_format.dart';
import 'stores_tab_state.dart';

/// The widest the card grid runs; past it the cards drift apart.
const double kStoresContentMaxWidth = 1200;

/// The narrowest a card is drawn in the grid at 1x text.
const double kStoreCardMinWidth = 360;

/// The list's width beside an open detail.
const double kStoresListWidth = 360;

void _openStoreSettings(WidgetRef ref) =>
    openSettingsTab(ref, anchor: SettingsAnchor.storeCredentials);

/// **The Stores tab**: every app on the App Store and Google Play, what wants
/// a look first — a rejection, a release in review or rolling out, new
/// reviews, a falling rating — then the rest; and one app's detail.
/// Read-only. The Karmashala server reads the stores, on open and on request;
/// this tab shows what it holds.
class StoresTabView extends ConsumerStatefulWidget {
  const StoresTabView({super.key});

  @override
  ConsumerState<StoresTabView> createState() => _StoresTabViewState();
}

class _StoresTabViewState extends ConsumerState<StoresTabView> {
  @override
  void initState() {
    super.initState();
    // Each time the tab opens, not only when the provider is first built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(storesProvider.notifier).refreshIfStale();
    });
  }

  @override
  Widget build(BuildContext context) {
    // A store connected while the tab is open is read without asking.
    ref.listen(
      storesProvider.select((async) {
        final view = async.value?.view;
        return view == null ? null : (view.apple != null, view.play != null);
      }),
      (previous, next) {
        if (previous == null || next == null) return;
        if ((next.$1 && !previous.$1) || (next.$2 && !previous.$2)) {
          ref.read(storesProvider.notifier).refresh();
        }
      },
    );
    return const WorkbenchTabScaffold(
      icon: AppIcons.package,
      title: 'Stores',
      body: _StoresBody(),
    );
  }
}

class _StoresBody extends ConsumerWidget {
  const _StoresBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(storesProvider);
    final state = async.value;
    if (state == null) {
      if (async.error case final error?) {
        return PanePlaceholder(
          icon: AppIcons.warning,
          message: error is DataRefused
              ? storeRefusalSentence(error)
              : 'The Karmashala server could not say how the stores stand.',
          action: TextButton(
            onPressed: () => ref.invalidate(storesProvider),
            child: const Text('Try again'),
          ),
        );
      }
      return const Center(
        child: InlineSpinner(
          size: InlineSpinnerSize.large,
          semanticsLabel: 'Asking the Karmashala server',
        ),
      );
    }
    final connected = state.connected;
    if (connected.isEmpty) {
      return PanePlaceholder(
        icon: AppIcons.package,
        message:
            'How every app is doing on the App Store and Google Play: what '
            'needs you, what is in review or rolling out, ratings, reviews, '
            'crash rates and downloads. Read-only.\n\n'
            'Import an App Store Connect key or a Google Play service '
            'account to begin.',
        action: FilledButton(
          onPressed: () => _openStoreSettings(ref),
          child: const Text('Open Settings → Stores'),
        ),
      );
    }
    final storeWide = state.storeWide;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusRow(dashboard: state),
        if (state.problem case final problem?)
          PaneNoticeBar(
            icon: AppIcons.warning,
            tone: NoticeTone.attention,
            message: problem,
          ),
        for (final store in StoreKind.values)
          if (!connected.contains(store))
            PaneNoticeBar(
              icon: AppIcons.linkBreak,
              message: '${store.label} is not connected.',
              action: TextButton(
                onPressed: () => _openStoreSettings(ref),
                child: const Text('Connect'),
              ),
            )
          else if (state.stores[store] case ReadingMissing<List<StoreApp>>(
            :final message,
          ))
            PaneNoticeBar(
              icon: AppIcons.warning,
              tone: NoticeTone.attention,
              message: '${store.label} could not list its apps. $message',
            ),
        for (final notice in _storeWideNotices(storeWide))
          PaneNoticeBar(
            icon: notice.fault ? AppIcons.warning : AppIcons.info,
            tone: notice.fault ? NoticeTone.attention : NoticeTone.neutral,
            message: notice.message,
            maxLines: 3,
            action: notice.settings
                ? TextButton(
                    onPressed: () => _openStoreSettings(ref),
                    child: const Text('Settings'),
                  )
                : null,
          ),
        Expanded(child: _Dashboard(dashboard: state)),
      ],
    );
  }
}

typedef _Notice = ({String message, bool fault, bool settings});

/// The failures every app of a store shares, one notice each: a fault says
/// what failed and why; setup still to do says it once per store, its
/// remedies run together (`… to see the rating and installs.`).
List<_Notice> _storeWideNotices(List<StoreWideMissing> missing) {
  final notices = <_Notice>[];
  final setup = <StoreKind, List<StoreWideMissing>>{};
  for (final failure in missing) {
    if (failure.expected) {
      setup.putIfAbsent(failure.store, () => []).add(failure);
      continue;
    }
    final areas = failure.areas.map((area) => area.label).join(', ');
    notices.add((
      message:
          '${failure.store.label} · $areas, for every app: ${failure.message}',
      fault: true,
      settings:
          failure.kind == StoreFailure.auth ||
          failure.kind == StoreFailure.permission,
    ));
  }
  for (final MapEntry(key: store, value: failures) in setup.entries) {
    notices.add((
      message:
          '${store.label} · ${_joinRemedies([for (final failure in failures) failure.message])}',
      fault: false,
      settings: failures.any(
        (failure) => failure.kind == StoreFailure.notConfigured,
      ),
    ));
  }
  return notices;
}

/// Remedies that differ only after "to see" as one: "Add X to see the
/// rating." and "Add X to see installs." are "Add X to see the rating and
/// installs."
String _joinRemedies(List<String> messages) {
  const cut = ' to see ';
  final heads = {
    for (final message in messages)
      message.contains(cut) ? message.split(cut).first : message,
  };
  if (messages.length < 2 ||
      heads.length != 1 ||
      !messages.first.contains(cut)) {
    return messages.join(' ');
  }
  final tails = [
    for (final message in messages)
      message.split(cut).skip(1).join(cut).replaceAll(RegExp(r'\.$'), ''),
  ];
  final joined = tails.length == 2
      ? tails.join(' and ')
      : '${tails.take(tails.length - 1).join(', ')} and ${tails.last}';
  return '${heads.single}$cut$joined.';
}

/// How old the data is, how far a refresh has got, and the way to ask for
/// one; a thin bar under it fills as a refresh reads app after app.
class _StatusRow extends ConsumerWidget {
  const _StatusRow({required this.dashboard});

  final StoresState dashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final at = dashboard.refreshedAt;
    final refreshing = dashboard.refreshing;
    final now = ref.watch(clockProvider).nowUtc();
    final age = at == null
        ? (refreshing ? 'Reading the stores…' : 'Not read yet')
        : 'Updated ${formatDataAge(now.difference(at))}';
    final total = dashboard.total;
    final progress = refreshing && total > 0
        ? ' · reading ${dashboard.done} of $total'
        : '';
    final apps = dashboard.view.apps.length;
    // How long the overview takes to fade from one state to the next; nothing
    // under reduced motion.
    final swap = Motion.of(context).base;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.xs,
            Insets.sm,
            Insets.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '$age$progress'),
                      if (!refreshing && apps > 0)
                        TextSpan(
                          text:
                              ' · $apps ${apps == 1 ? 'listing' : 'listings'}',
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              TextButton.icon(
                onPressed: refreshing
                    ? null
                    : () => ref.read(storesProvider.notifier).refresh(),
                icon: refreshing
                    ? const InlineSpinner(semanticsLabel: 'Reading the stores')
                    : const Icon(
                        AppIcons.arrowsClockwise,
                        size: Chrome.iconAction,
                      ),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
        // Always two pixels tall, so starting and ending a refresh moves
        // nothing below it.
        SizedBox(
          height: 2,
          child: AnimatedOpacity(
            opacity: refreshing ? 1 : 0,
            duration: swap,
            child: refreshing
                ? TweenAnimationBuilder<double>(
                    tween: Tween(end: total > 0 ? dashboard.done / total : 0),
                    duration: swap,
                    builder: (context, value, _) => LinearProgressIndicator(
                      value: total > 0 ? value : null,
                      minHeight: 2,
                      backgroundColor: Colors.transparent,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// The overview and the selected app's detail: beside it at expanded width,
/// in its place below it.
class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.dashboard});

  final StoresState dashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = dashboard.groups;
    // How long the overview takes to fade from one state to the next; nothing
    // under reduced motion.
    final swap = Motion.of(context).base;
    if (groups.isEmpty) {
      final Widget body;
      if (dashboard.refreshing) {
        body = const _Skeletons(key: ValueKey('skeletons'));
      } else {
        body = PanePlaceholder(
          key: const ValueKey('empty'),
          icon: AppIcons.package,
          message: dashboard.stores.isEmpty
              ? 'Nothing has been read from the stores yet. Refresh to read '
                    'them.'
              : 'The stores list no apps for these credentials.',
        );
      }
      return AnimatedSwitcher(duration: swap, child: body);
    }
    final selection = ref.watch(storesSelectionProvider);
    StoreAppGroup? selected;
    for (final group in groups) {
      if (group.has(selection)) selected = group;
    }
    void select(String? appKey) =>
        ref.read(storesSelectionProvider.notifier).select(appKey);

    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final expanded = WidthClass.of(width, textScaler: scaler).isExpanded;
        final gutter = expanded ? Insets.xl : Insets.lg;
        final open = selected;
        if (open == null) {
          return SingleChildScrollView(
            key: const PageStorageKey('stores-overview'),
            padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, Insets.xl),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kStoresContentMaxWidth,
                ),
                child: _Overview(
                  groups: groups,
                  refreshedAt: dashboard.refreshedAt,
                  selected: null,
                  // One column below expanded, whatever would fit (§6).
                  singleColumn: !expanded,
                  onSelect: select,
                ),
              ),
            ),
          );
        }
        if (!expanded) {
          return PopScope(
            // Back leaves the detail before it leaves the page.
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) select(null);
            },
            child: StoreGroupDetail(
              group: open,
              pushed: true,
              onClose: () => select(null),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: WidthClass.scaleBreakpoint(kStoresListWidth, scaler),
              child: SingleChildScrollView(
                key: const PageStorageKey('stores-list'),
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.md,
                  Insets.lg,
                  Insets.xl,
                ),
                child: _Overview(
                  groups: groups,
                  refreshedAt: dashboard.refreshedAt,
                  selected: open.key,
                  singleColumn: true,
                  onSelect: select,
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: StoreGroupDetail(
                key: ValueKey(open.key),
                group: open,
                pushed: false,
                onClose: () => select(null),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The counts that matter as filters, then the apps — sectioned by what
/// they need when every app is shown.
class _Overview extends ConsumerWidget {
  const _Overview({
    required this.groups,
    required this.refreshedAt,
    required this.selected,
    required this.singleColumn,
    required this.onSelect,
  });

  final List<StoreAppGroup> groups;
  final DateTime? refreshedAt;
  final String? selected;
  final bool singleColumn;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(storesFilterProvider);
    bool inFilter(StoresFilter filter, StoreAppGroup group) => switch (filter) {
      StoresFilter.all => true,
      StoresFilter.attention => group.needsAttention,
      StoresFilter.inProgress => !group.needsAttention && group.inFlight,
      StoresFilter.newReviews => group.newReviewCount > 0,
    };
    final counts = {
      for (final f in StoresFilter.values)
        f: groups.where((group) => inFilter(f, group)).length,
    };
    final sections = <(String?, List<StoreAppGroup>)>[];
    if (filter == StoresFilter.all) {
      final attention = groups.where((g) => g.needsAttention).toList();
      final moving = groups
          .where((g) => !g.needsAttention && g.inFlight)
          .toList();
      final rest = groups
          .where((g) => !g.needsAttention && !g.inFlight)
          .toList();
      final sectioned = attention.isNotEmpty || moving.isNotEmpty;
      if (attention.isNotEmpty) sections.add(('Needs attention', attention));
      if (moving.isNotEmpty) sections.add(('In progress', moving));
      if (rest.isNotEmpty) {
        sections.add((sectioned ? 'Everything else' : null, rest));
      }
    } else {
      sections.add((
        null,
        [
          for (final g in groups)
            if (inFilter(filter, g)) g,
        ],
      ));
    }
    final shown = sections.fold(0, (sum, section) => sum + section.$2.length);
    // How long the overview takes to fade from one state to the next; nothing
    // under reduced motion.
    final swap = Motion.of(context).base;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryStrip(
          counts: counts,
          filter: filter,
          compact: singleColumn,
          onPick: ref.read(storesFilterProvider.notifier).toggle,
        ),
        const SizedBox(height: Insets.lg),
        AnimatedSwitcher(
          duration: swap,
          child: KeyedSubtree(
            key: ValueKey(filter),
            child: shown == 0
                ? _NothingToShow(filter: filter)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, (title, members)) in sections.indexed) ...[
                        if (title != null)
                          Padding(
                            padding: EdgeInsets.only(
                              top: i == 0 ? 0 : Insets.md,
                              bottom: Insets.sm,
                            ),
                            child: Semantics(
                              header: true,
                              child: EyebrowLabel('$title · ${members.length}'),
                            ),
                          ),
                        _CardGrid(
                          groups: members,
                          refreshedAt: refreshedAt,
                          selected: selected,
                          singleColumn: singleColumn,
                          onSelect: onSelect,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// The four counts — needs attention, in progress, new reviews, all — as
/// filters: tiles with the figure large where there is room, chips where not.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.counts,
    required this.filter,
    required this.compact,
    required this.onPick,
  });

  final Map<StoresFilter, int> counts;
  final StoresFilter filter;
  final bool compact;
  final ValueChanged<StoresFilter> onPick;

  static const _order = [
    StoresFilter.attention,
    StoresFilter.inProgress,
    StoresFilter.newReviews,
    StoresFilter.all,
  ];

  Color _ink(BuildContext context, StoresFilter f, int count) {
    final semantic = SemanticColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (count == 0 || f == StoresFilter.all) return scheme.onSurface;
    return switch (f) {
      StoresFilter.attention => semantic.failure,
      StoresFilter.inProgress => semantic.working,
      StoresFilter.newReviews => semantic.unread,
      StoresFilter.all => scheme.onSurface,
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final roomy =
            !compact &&
            constraints.maxWidth >= WidthClass.scaleBreakpoint(560, scaler);
        if (!roomy) {
          return Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              for (final f in _order)
                ChoiceChip(
                  label: Text('${f.label} ${counts[f] ?? 0}'),
                  selected: filter == f,
                  onSelected: f != StoresFilter.all && (counts[f] ?? 0) == 0
                      ? null
                      : (_) => onPick(f),
                ),
            ],
          );
        }
        return Row(
          children: [
            for (final (i, f) in _order.indexed) ...[
              if (i > 0) const SizedBox(width: Insets.md),
              Expanded(
                child: _SummaryTile(
                  label: f.label,
                  count: counts[f] ?? 0,
                  ink: _ink(context, f, counts[f] ?? 0),
                  selected: filter == f,
                  onTap: f != StoresFilter.all && (counts[f] ?? 0) == 0
                      ? null
                      : () => onPick(f),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.count,
    required this.ink,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final Color ink;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '$label: $count',
      child: ExcludeSemantics(
        child: Material(
          color: selected
              ? SurfaceTones.of(context).selected
              : scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$count',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: ink,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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

class _NothingToShow extends StatelessWidget {
  const _NothingToShow({required this.filter});

  final StoresFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = switch (filter) {
      StoresFilter.attention => 'Nothing needs you right now.',
      StoresFilter.inProgress => 'No release is in review or rolling out.',
      StoresFilter.newReviews => 'No reviews this week.',
      StoresFilter.all => 'No apps.',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxl),
      child: Column(
        children: [
          Icon(
            AppIcons.checkCircle,
            size: Chrome.iconHero,
            color: SemanticColors.of(context).idle,
          ),
          const SizedBox(height: Insets.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The shape of the overview while the stores are read for the first time.
class _Skeletons extends StatelessWidget {
  const _Skeletons({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Reading the stores',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.lg),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kStoresContentMaxWidth),
            child: const _CardGrid.skeletons(),
          ),
        ),
      ),
    );
  }
}

/// The cards in as many columns as fit, each row as wide as the grid.
class _CardGrid extends StatelessWidget {
  const _CardGrid({
    required this.groups,
    required this.refreshedAt,
    required this.selected,
    required this.singleColumn,
    required this.onSelect,
  }) : skeletons = 0;

  const _CardGrid.skeletons()
    : groups = const [],
      refreshedAt = null,
      selected = null,
      singleColumn = false,
      onSelect = null,
      skeletons = 6;

  final List<StoreAppGroup> groups;
  final DateTime? refreshedAt;
  final String? selected;
  final bool singleColumn;
  final ValueChanged<String?>? onSelect;
  final int skeletons;

  static const maxColumns = 3;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final count = skeletons > 0 ? skeletons : groups.length;
    Widget cell(int i) {
      if (skeletons > 0) return const StoreCardSkeleton();
      final group = groups[i];
      return StoreGroupCard(
        group: group,
        refreshedAt: refreshedAt,
        selected: group.key == selected,
        onTap: () => onSelect?.call(group.key),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final card = WidthClass.scaleBreakpoint(kStoreCardMinWidth, scaler);
        final fit = ((constraints.maxWidth + Insets.md) / (card + Insets.md))
            .floor();
        final columns = singleColumn ? 1 : fit.clamp(1, maxColumns);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var start = 0; start < count; start += columns)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = start; i < start + columns; i++) ...[
                        if (i > start) const SizedBox(width: Insets.md),
                        Expanded(
                          child: i < count ? cell(i) : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
