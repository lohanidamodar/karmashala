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
const double kStoresListWidth = 340;

void _openStoreSettings(WidgetRef ref) =>
    openSettingsTab(ref, anchor: SettingsAnchor.storeCredentials);

/// **The Stores tab**: every app on the App Store and Google Play — what is
/// live, what is pending, its rating and downloads — and one app's detail.
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
    final theme = Theme.of(context);
    // Under a page that already names it (the phone's More), no second title.
    final untitled = PaneTitleOverride.maybeOf(context) != null;
    return Scaffold(
      appBar: untitled
          ? null
          : AppBar(
              toolbarHeight: 44,
              // A workbench tab: an implied back button would pop the app's
              // route.
              automaticallyImplyLeading: false,
              title: Row(
                children: [
                  Icon(AppIcons.package, color: theme.colorScheme.tertiary),
                  const SizedBox(width: Insets.sm),
                  const Flexible(
                    child: Text(
                      'Stores',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
      body: const _StoresBody(),
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
            'is live, what is in review or rolling out, ratings, reviews, '
            'crash rates and downloads. Read-only.\n\n'
            'Import an App Store Connect key or a Google Play service '
            'account to begin.',
        action: FilledButton(
          onPressed: () => _openStoreSettings(ref),
          child: const Text('Open Settings → Stores'),
        ),
      );
    }
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
              message: '${store.label}: $message',
            ),
        Expanded(child: _Dashboard(dashboard: state)),
      ],
    );
  }
}

/// How old the data is, how far a refresh has got, and the way to ask for one.
class _StatusRow extends ConsumerWidget {
  const _StatusRow({required this.dashboard});

  final StoresState dashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final at = dashboard.refreshedAt;
    final refreshing = dashboard.refreshing;
    final now = ref.watch(clockProvider).nowUtc();
    final age = at == null
        ? (refreshing ? 'Reading the stores…' : 'Not read yet')
        : 'Updated ${formatDataAge(now.difference(at))}';
    final progress = refreshing && dashboard.total > 0
        ? ' · reading ${dashboard.done} of ${dashboard.total}'
        : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.xs,
        Insets.sm,
        Insets.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$age$progress',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
                : const Icon(AppIcons.arrowsClockwise, size: Chrome.iconAction),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

/// The cards, and the selected app's detail: beside them at expanded width,
/// in their place below it.
class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.dashboard});

  final StoresState dashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = dashboard.groups;
    if (groups.isEmpty) {
      return PanePlaceholder(
        icon: AppIcons.package,
        message: dashboard.refreshing
            ? 'Reading the stores…'
            : dashboard.stores.isEmpty
            ? 'Nothing has been read from the stores yet. Refresh to read '
                  'them.'
            : 'The stores list no apps for these credentials.',
      );
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
            padding: EdgeInsets.fromLTRB(gutter, Insets.sm, gutter, Insets.xl),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kStoresContentMaxWidth,
                ),
                child: _CardGrid(
                  groups: groups,
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
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.sm,
                  Insets.lg,
                  Insets.xl,
                ),
                child: _CardGrid(
                  groups: groups,
                  selected: open.key,
                  singleColumn: true,
                  onSelect: select,
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: StoreGroupDetail(
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

/// The cards in as many columns as fit, each row as wide as the grid.
class _CardGrid extends StatelessWidget {
  const _CardGrid({
    required this.groups,
    required this.selected,
    required this.singleColumn,
    required this.onSelect,
  });

  final List<StoreAppGroup> groups;
  final String? selected;
  final bool singleColumn;
  final ValueChanged<String?> onSelect;

  static const maxColumns = 3;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
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
            for (var start = 0; start < groups.length; start += columns)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = start; i < start + columns; i++) ...[
                      if (i > start) const SizedBox(width: Insets.md),
                      Expanded(
                        child: i < groups.length
                            ? StoreGroupCard(
                                group: groups[i],
                                selected: groups[i].key == selected,
                                onTap: () => onSelect(groups[i].key),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
