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
import '../application/store_summary.dart';
import '../application/stores_controller.dart';
import '../application/stores_layout_prefs.dart';
import 'store_app_card.dart';
import 'store_app_detail.dart';
import 'store_summary_table.dart';
import 'stores_format.dart';
import 'stores_tab_state.dart';

part 'stores_tab_view/dashboard.dart';
part 'stores_tab_view/empty_states.dart';
part 'stores_tab_view/status_row.dart';
part 'stores_tab_view/filter_row.dart';

/// The widest the card grid runs; past it the cards drift apart.
const double kStoresContentMaxWidth = 1200;

/// The narrowest a card is drawn in the grid at 1x text.
const double kStoreCardMinWidth = 360;

/// The list's width beside an open detail.
const double kStoresListWidth = 360;

void _openStoreSettings(WidgetRef ref) =>
    openSettingsTab(ref, anchor: SettingsAnchor.storeCredentials);

/// **The Stores tab**: every app on the App Store and Google Play in one
/// list, as a table or as cards, what wants a look first — a rejection, a
/// release in review or rolling out, new reviews, a falling rating — then the
/// rest; and one app's detail.
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
    final hasApps = ref.watch(
      storesProvider.select((async) => async.value?.groups.isNotEmpty ?? false),
    );
    final chosen = ref.watch(storesLayoutProvider);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Unpicked, a desktop gets the table and a phone the cards.
        final layout =
            chosen ??
            (WidthClass.of(constraints.maxWidth, textScaler: scaler).isExpanded
                ? StoresLayout.table
                : StoresLayout.cards);
        return WorkbenchTabScaffold(
          icon: AppIcons.package,
          title: 'Stores',
          controls: [
            if (hasApps)
              CompactSegmented<StoresLayout>(
                key: const ValueKey('stores-layout'),
                segments: [
                  for (final option in StoresLayout.values)
                    ButtonSegment(value: option, label: Text(option.label)),
                ],
                selected: layout,
                onChanged: ref.read(storesLayoutProvider.notifier).pick,
              ),
          ],
          body: _StoresBody(layout: layout),
        );
      },
    );
  }
}

class _StoresBody extends ConsumerWidget {
  const _StoresBody({required this.layout});

  final StoresLayout layout;

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
        Expanded(
          child: _Dashboard(dashboard: state, layout: layout),
        ),
      ],
    );
  }
}
