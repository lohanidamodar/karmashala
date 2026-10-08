// The detail's header: icon, name, ids, store presence and actions.

part of '../store_app_detail.dart';

/// The icon, the name, the ids, and each store the app is on with what is
/// live there.
class _Header extends StatelessWidget {
  const _Header({
    required this.group,
    required this.pushed,
    required this.onClose,
    required this.layout,
  });

  final StoreAppGroup group;
  final bool pushed;
  final VoidCallback onClose;
  final _Layout layout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final narrow = layout == _Layout.narrow;
    final iconSize = StoreAppIconView.detailSize(context) - (narrow ? 8 : 0);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        pushed ? Insets.xs : layout.gutter,
        Insets.md,
        Insets.xs,
        Insets.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pushed) ...[
            IconButton(
              tooltip: 'Back to all apps',
              icon: const Icon(AppIcons.arrowLeft),
              onPressed: onClose,
            ),
            const SizedBox(width: Insets.xs),
          ],
          StoreAppIconView(icon: group.icon, name: group.name, size: iconSize),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    group.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (narrow
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.titleLarge)
                            ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: Insets.xxs),
                // Combined by hand, each store's id on its own line.
                for (final id in storeGroupIdLines(group))
                  SelectableText(
                    id,
                    // On a phone a long id wraps rather than scrolls.
                    maxLines: narrow ? null : 1,
                    style: MonoStyles.body.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: Insets.sm),
                Wrap(
                  spacing: Insets.lg,
                  runSpacing: Insets.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final entry in group.entries)
                      _StorePresence(entry: entry),
                    if (group.combinedManually) const CombinedManuallyChip(),
                  ],
                ),
              ],
            ),
          ),
          if (!pushed) ...[
            const SizedBox(width: Insets.sm),
            IconButton(
              tooltip: 'Close details',
              icon: const Icon(AppIcons.x),
              onPressed: onClose,
            ),
          ],
        ],
      ),
    );
  }
}

/// One store in the header: its logo and name, and the version live there.
class _StorePresence extends StatelessWidget {
  const _StorePresence({required this.entry});

  final StoreEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final store = entry.app.store;
    final (status, isLive) = switch (entry.snapshot) {
      null => ('Not read yet', false),
      StoreAppSnapshot(releases: ReadingMissing()) => (
        'Releases unread',
        false,
      ),
      StoreAppSnapshot(:final live?) => (formatVersion(live), true),
      _ => ('Not live', false),
    };
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      container: true,
      label:
          '${store.label}: ${isLive ? 'live $status' : status.toLowerCase()}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: StoreLogo.named(
                store,
                size: Chrome.iconAction,
                color: scheme.onSurface,
                style: style?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: Insets.sm),
            if (isLive) ...[
              Container(
                width: Chrome.dot,
                height: Chrome.dot,
                decoration: BoxDecoration(
                  color: SemanticColors.of(context).idle,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Insets.xs),
            ],
            Flexible(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isLive
                    ? style?.copyWith(fontWeight: FontWeight.w500)
                    : style?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Each store's console and listing, one click away, and combining.
class _Actions extends ConsumerWidget {
  const _Actions({required this.group});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.read(openExternalUrlProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          children: [
            for (final entry in group.entries)
              for (final link in storeLinks(entry.app))
                OutlinedButton.icon(
                  onPressed: () => open(link.url),
                  icon: const Icon(
                    AppIcons.arrowSquareOut,
                    size: Chrome.iconAction,
                  ),
                  label: Text(
                    link.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          ],
        ),
        if (group.combined != StoreCombined.byId) ...[
          const SizedBox(height: Insets.xs),
          StoreCombineBar(group: group),
        ],
      ],
    );
  }
}
