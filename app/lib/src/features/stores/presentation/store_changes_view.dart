import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show StoreAppChanges, StoreChange;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../application/store_groups.dart';
import '../application/stores_controller.dart';
import 'store_badges.dart';
import 'store_logo.dart';
import 'stores_format.dart';

/// On a card: something about the app changed since it was last opened.
/// Gone once the app is opened.
class StoreChangedMarker extends StatelessWidget {
  const StoreChangedMarker({required this.group, super.key});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context) {
    final unseen = [
      for (final held in group.changes)
        if (!held.seen) held,
    ];
    if (unseen.isEmpty) return const SizedBox.shrink();
    final attention = unseen.any((held) => held.attention);
    final semantic = SemanticColors.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: StatusPill(
        key: const ValueKey('store-changed-marker'),
        label: 'Changed since last refresh',
        icon: AppIcons.bellSimple,
        color: attention
            ? semantic.attention
            : Theme.of(context).colorScheme.primary,
        tooltip: [for (final held in unseen) held.sentence].join('\n'),
      ),
    );
  }
}

/// At the top of an app's detail: what the last read that changed it found,
/// per store, a line each, those that want a person in their colour.
class StoreWhatChanged extends ConsumerWidget {
  const StoreWhatChanged({required this.group, super.key});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.watch(clockProvider).nowUtc();
    final sets = group.changes;
    final both = group.entries.length > 1;
    return Column(
      key: const ValueKey('store-what-changed'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, held) in sets.indexed) ...[
          if (i > 0) const SizedBox(height: Insets.md),
          Row(
            children: [
              if (both) ...[
                StoreLogo(
                  held.app.store,
                  size: MediaQuery.textScalerOf(context).scale(Chrome.icon),
                ),
                const SizedBox(width: Insets.sm),
              ],
              Expanded(
                child: Text(
                  'Found ${formatDataAge(now.difference(held.at))}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          for (final change in _loudestFirst(held))
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: _ChangeLine(change: change),
            ),
        ],
      ],
    );
  }

  static List<StoreChange> _loudestFirst(StoreAppChanges held) => [
    ...held.changes.where((change) => change.attention),
    ...held.changes.where((change) => !change.attention),
  ];
}

class _ChangeLine extends StatelessWidget {
  const _ChangeLine({required this.change});

  final StoreChange change;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = change.attention
        ? SemanticColors.of(context).attention
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Insets.xxs),
          child: Icon(
            change.attention ? AppIcons.warningCircle : AppIcons.circle,
            size: Chrome.icon,
            color: color,
            semanticLabel: change.attention ? 'Wants a look' : null,
          ),
        ),
        const SizedBox(width: Insets.sm),
        Expanded(child: Text(change.text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

/// Marks [group]'s changes seen while it is on screen: when it opens, and
/// when a read finds more about it while open.
class StoreSeenOnOpen extends ConsumerStatefulWidget {
  const StoreSeenOnOpen({required this.group, required this.child, super.key});

  final StoreAppGroup group;
  final Widget child;

  @override
  ConsumerState<StoreSeenOnOpen> createState() => _StoreSeenOnOpenState();
}

class _StoreSeenOnOpenState extends ConsumerState<StoreSeenOnOpen> {
  @override
  void initState() {
    super.initState();
    _markSoon();
  }

  @override
  void didUpdateWidget(StoreSeenOnOpen old) {
    super.didUpdateWidget(old);
    _markSoon();
  }

  /// After the frame: a provider may not be written while widgets build.
  void _markSoon() {
    if (!widget.group.changedUnseen) return;
    final keys = [for (final entry in widget.group.entries) entry.app.key];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(storesProvider.notifier).markSeen(keys);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
