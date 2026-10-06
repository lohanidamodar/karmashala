import 'package:flutter/material.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../application/store_groups.dart';
import '../application/stores_controller.dart';
import 'store_app_icon.dart';

/// More apps than this in the picker and it offers a search field.
const int _kSearchAbove = 8;

StoreKind _otherStore(StoreKind store) => switch (store) {
  StoreKind.appStore => StoreKind.googlePlay,
  StoreKind.googlePlay => StoreKind.appStore,
};

/// The ids under an app's name: its bundle id, or — combined by hand — each
/// store's, named.
List<String> storeGroupIdLines(StoreAppGroup group) => group.combinedManually
    ? [
        for (final entry in group.entries)
          '${entry.app.store.label}: ${entry.app.bundleId}',
      ]
    : [group.bundleId];

/// A small "Combined manually" mark, so a pair combined by hand is not taken
/// for one whose ids match.
class CombinedManuallyChip extends StatelessWidget {
  const CombinedManuallyChip({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message:
          'Combined by hand: the App Store bundle id and the Play package '
          'name differ.',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.hair,
        ),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.linkSimple,
              size: Chrome.iconAction,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: Insets.xs),
            Text(
              'Combined manually',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// In an app's detail: "Combine with…" for an app on one store, "Separate"
/// for a pair combined by hand, nothing for a pair whose ids match.
class StoreCombineBar extends ConsumerWidget {
  const StoreCombineBar({required this.group, super.key});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = group.link;
    if (link != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _separate(context, ref, link),
          icon: const Icon(AppIcons.linkBreak, size: Chrome.iconAction),
          label: const Text('Separate'),
        ),
      );
    }
    final only = group.onlyStore;
    if (only == null) return const SizedBox.shrink();
    final other = _otherStore(only);
    final state = ref.watch(storesProvider).value;
    final candidates = _candidates(state, other);
    final reason = state == null || !state.connected.contains(other)
        ? '${other.label} is not connected.'
        : candidates.isEmpty
        ? '${other.label} lists no apps to combine with.'
        : null;
    final theme = Theme.of(context);
    final mine = group.entries.single.app;
    // The same name, standing alone on the other store: most likely the same
    // app under another id, offered in one click.
    final likely = [
      for (final (entry, home) in candidates)
        if (home.combined == StoreCombined.alone &&
            _sameName(entry.app.name, mine.name))
          entry.app,
    ];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      children: [
        if (likely.length == 1)
          FilledButton.tonalIcon(
            onPressed: () => _link(context, ref, mine, likely.single),
            icon: const Icon(AppIcons.linkSimple, size: Chrome.iconAction),
            label: Text('Combine with ${likely.single.id} on ${other.label}'),
          ),
        TextButton.icon(
          onPressed: reason != null
              ? null
              : () => _combine(context, ref, other, candidates),
          icon: const Icon(AppIcons.linkSimple, size: Chrome.iconAction),
          label: const Text('Combine with…'),
        ),
        Text(
          reason ??
              'The same app on ${other.label} under another '
                  '${other == StoreKind.googlePlay ? 'package name' : 'bundle id'}.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Every app on [other], by name, with the group it is in now.
  static List<(StoreEntry, StoreAppGroup)> _candidates(
    StoresState? state,
    StoreKind other,
  ) {
    if (state == null) return const [];
    return [
      for (final group in state.groups)
        for (final entry in group.entries)
          if (entry.app.store == other) (entry, group),
    ]..sort(
      (a, b) =>
          a.$1.app.name.toLowerCase().compareTo(b.$1.app.name.toLowerCase()),
    );
  }

  Future<void> _combine(
    BuildContext context,
    WidgetRef ref,
    StoreKind other,
    List<(StoreEntry, StoreAppGroup)> candidates,
  ) async {
    final mine = group.entries.single.app;
    final picked = await showAdaptiveModal<StoreApp>(
      context: context,
      title: 'Combine ${mine.name} with a ${other.label} app',
      heightFactor: candidates.length > _kSearchAbove ? 0.75 : null,
      builder: (context) => _CombinePicker(
        candidates: candidates,
        searchable: candidates.length > _kSearchAbove,
      ),
    );
    if (picked == null || !context.mounted) return;
    await _link(context, ref, mine, picked);
  }

  static bool _sameName(String a, String b) {
    String plain(String name) => name.toLowerCase().replaceAll(
      RegExp(r'[^\p{L}\p{N}]+', unicode: true),
      '',
    );
    return plain(a).isNotEmpty && plain(a) == plain(b);
  }

  Future<void> _link(
    BuildContext context,
    WidgetRef ref,
    StoreApp mine,
    StoreApp picked,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final (apple, play) = mine.store == StoreKind.appStore
        ? (mine, picked)
        : (picked, mine);
    final problem = await ref
        .read(storesProvider.notifier)
        .combine(StoreAppLink(appStoreId: apple.id, packageName: play.id));
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          problem ??
              'Combined ${apple.name} (App Store) with ${play.name} '
                  '(Google Play).',
        ),
      ),
    );
  }

  Future<void> _separate(
    BuildContext context,
    WidgetRef ref,
    StoreAppLink link,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = ref.read(storesProvider.notifier);
    final names = group.entries.map((entry) => entry.app.name).toSet();
    final problem = await controller.separate(link);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          problem ??
              'Separated ${names.join(' and ')}: each now shows on its own.',
        ),
        action: problem != null
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () => controller.combine(link),
              ),
      ),
    );
  }
}

/// The other store's apps to combine with; pops the one picked.
class _CombinePicker extends StatefulWidget {
  const _CombinePicker({required this.candidates, required this.searchable});

  final List<(StoreEntry, StoreAppGroup)> candidates;
  final bool searchable;

  @override
  State<_CombinePicker> createState() => _CombinePickerState();
}

class _CombinePickerState extends State<_CombinePicker> {
  String _query = '';

  bool _matches(StoreApp app) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return app.name.toLowerCase().contains(query) ||
        app.id.toLowerCase().contains(query) ||
        app.bundleId.toLowerCase().contains(query);
  }

  /// Why picking this app changes another pair, or null when it does not.
  static String? _note(StoreEntry entry, StoreAppGroup group) =>
      switch (group.combined) {
        StoreCombined.alone => null,
        StoreCombined.manually =>
          'Combined by hand with ${_partner(entry, group)}',
        StoreCombined.byId => 'On both stores as ${group.bundleId}',
      };

  static String _partner(StoreEntry entry, StoreAppGroup group) => group.entries
      .where((other) => other.app != entry.app)
      .map((other) => other.app.name)
      .join(', ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final touch = UiDensity.of(context).isTouch;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final shown = [
      for (final candidate in widget.candidates)
        if (_matches(candidate.$1.app)) candidate,
    ];
    final tiles = [
      for (final (entry, group) in shown)
        ListTile(
          dense: !touch,
          leading: StoreAppIconView(
            icon: entry.icon,
            name: entry.app.name,
            size: StoreAppIconView.listSize(context),
          ),
          title: Text(
            entry.app.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [entry.app.id, ?_note(entry, group)].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          onTap: () => Navigator.of(context).pop(entry.app),
        ),
    ];
    if (!widget.searchable) {
      return Column(mainAxisSize: MainAxisSize.min, children: tiles);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            0,
            Insets.lg,
            Insets.sm,
          ),
          child: SearchField(
            autofocus: !touch,
            decoration: const InputDecoration(
              prefixIcon: Icon(AppIcons.magnifyingGlass),
              hintText: 'Search by name or id',
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text('No app matches.', style: muted))
              : ListView(children: tiles),
        ),
      ],
    );
  }
}
