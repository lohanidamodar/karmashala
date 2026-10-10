import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../../sessions/presentation/hand_to_session.dart';
import '../application/store_attention.dart';
import '../application/store_groups.dart';
import '../application/store_prompts.dart';
import 'store_badges.dart';
import 'store_logo.dart';
import 'stores_format.dart';

/// Reviews shown before "Show more".
const int _kReviewPage = 20;

/// Every store's reviews of one app in one list, newest first, with the
/// spread of stars and filters by store, stars and whether answered.
class StoreReviewsSection extends StatefulWidget {
  const StoreReviewsSection({
    required this.group,
    this.sideBySide = false,
    super.key,
  });

  final StoreAppGroup group;

  /// The spread and the filters in a column beside the reviews, where the
  /// detail is wide, rather than above them.
  final bool sideBySide;

  /// The side column's width at 1x text.
  static const double sideWidth = 280;

  @override
  State<StoreReviewsSection> createState() => _StoreReviewsSectionState();
}

class _StoreReviewsSectionState extends State<StoreReviewsSection> {
  StoreKind? _store;
  final Set<int> _stars = {};
  bool _unanswered = false;
  int _shown = _kReviewPage;

  @override
  void didUpdateWidget(StoreReviewsSection old) {
    super.didUpdateWidget(old);
    if (old.group.key != widget.group.key) {
      _store = null;
      _stars.clear();
      _unanswered = false;
      _shown = _kReviewPage;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final all = <(StoreKind, StoreReview, DateTime)>[];
    final missing = <Widget>[];
    final withReviews = <StoreKind>{};
    var read = false;
    for (final entry in widget.group.entries) {
      final store = entry.app.store;
      switch (entry.snapshot?.reviews) {
        case ReadingValue(:final value, :final checkedAt):
          read = true;
          if (value.isNotEmpty) withReviews.add(store);
          for (final review in value) {
            all.add((store, review, checkedAt));
          }
        case final ReadingMissing<List<StoreReview>> reading:
          missing.add(
            MissingReadingLine(
              what: '${store.label} reviews',
              reading: reading,
            ),
          );
        case null:
          break;
      }
    }
    all.sort((a, b) => b.$2.createdAt.compareTo(a.$2.createdAt));
    final shown = [
      for (final item in all)
        if ((_store == null || item.$1 == _store) &&
            (_stars.isEmpty || _stars.contains(item.$2.rating)) &&
            (!_unanswered || !item.$2.answered))
          item,
    ];
    final onPlay = widget.group.entries.any(
      (entry) => entry.app.store == StoreKind.googlePlay,
    );

    final playNote = onPlay
        ? Text(
            'Google Play’s API returns only reviews with text from the '
            'last week; older ones are not gone, only not shown here.',
            style: muted,
          )
        : null;
    final summary = [
      for (final line in missing) ...[line, const SizedBox(height: Insets.sm)],
      if (all.isNotEmpty) ...[
        _Spread(reviews: [for (final item in all) item.$2]),
        const SizedBox(height: Insets.md),
        _filters(withReviews, all),
        const SizedBox(height: Insets.md),
      ],
    ];
    final list = [
      if (!read && missing.isEmpty)
        Text('Not read yet. Refresh to read them.', style: muted)
      else if (read && all.isEmpty)
        Text('No reviews yet.', style: muted)
      else if (all.isNotEmpty && shown.isEmpty)
        Text('No reviews match these filters.', style: muted),
      for (final (store, review, readAt) in shown.take(_shown))
        _ReviewCard(
          store: store,
          app: widget.group.entries
              .firstWhere((entry) => entry.app.store == store)
              .app,
          review: review,
          fresh: readAt.difference(review.createdAt) <= kNewReviewWindow,
          showStore: widget.group.entries.length > 1,
        ),
      if (shown.length > _shown)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => setState(() => _shown += _kReviewPage),
            child: Text('Show ${shown.length - _shown} more'),
          ),
        ),
    ];

    if (widget.sideBySide && all.isNotEmpty) {
      // Each side traversed whole: filters first, then what they filter.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: WidthClass.scaleBreakpoint(
              StoreReviewsSection.sideWidth,
              MediaQuery.textScalerOf(context),
            ),
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [...summary, ?playNote],
              ),
            ),
          ),
          const SizedBox(width: Insets.xl),
          Expanded(
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: list,
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...summary,
        ...list,
        if (playNote != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.sm),
            child: playNote,
          ),
      ],
    );
  }

  Widget _filters(
    Set<StoreKind> withReviews,
    List<(StoreKind, StoreReview, DateTime)> all,
  ) {
    final unanswered = all.where((item) => !item.$2.answered).length;
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (withReviews.length > 1) ...[
          for (final store in <StoreKind?>[null, ...StoreKind.values])
            ChoiceChip(
              label: store == null
                  ? const Text('Both stores')
                  : StoreLogo.named(store),
              selected: _store == store,
              onSelected: (_) => setState(() {
                _store = store;
                _shown = _kReviewPage;
              }),
            ),
          const SizedBox(width: Insets.sm),
        ],
        for (var stars = 5; stars >= 1; stars--)
          FilterChip(
            label: Text('$stars ★'),
            tooltip: '$stars-star reviews',
            selected: _stars.contains(stars),
            onSelected: (on) => setState(() {
              on ? _stars.add(stars) : _stars.remove(stars);
              _shown = _kReviewPage;
            }),
          ),
        const SizedBox(width: Insets.sm),
        FilterChip(
          label: Text('Unanswered ($unanswered)'),
          selected: _unanswered,
          onSelected: (on) => setState(() {
            _unanswered = on;
            _shown = _kReviewPage;
          }),
        ),
      ],
    );
  }
}

/// How the reviews read spread over the stars, a bar per star.
class _Spread extends StatelessWidget {
  const _Spread({required this.reviews});

  final List<StoreReview> reviews;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final counts = {
      for (var stars = 5; stars >= 1; stars--)
        stars: reviews.where((review) => review.rating == stars).length,
    };
    final most = counts.values.fold(1, (a, b) => a > b ? a : b);
    final rated = reviews.where((review) => review.rating > 0).toList();
    final average = rated.isEmpty
        ? null
        : rated.fold(0, (sum, review) => sum + review.rating) / rated.length;
    final unanswered = reviews.where((review) => !review.answered).length;
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final bars = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final MapEntry(key: stars, value: count) in counts.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.hair),
            child: Row(
              children: [
                SizedBox(width: 12, child: Text('$stars', style: style)),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(
                      value: count / most,
                      minHeight: 6,
                      color: stars <= 2 ? semantic.attention : semantic.idle,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                SizedBox(
                  width: 28,
                  child: Text(
                    '$count',
                    textAlign: TextAlign.end,
                    style: style?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          average == null ? '—' : average.toStringAsFixed(1),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          '${reviews.length} ${reviews.length == 1 ? 'review' : 'reviews'} '
          'read',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Text(
          '$unanswered unanswered',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Semantics(
      label:
          'Of ${reviews.length} reviews read: '
          '${[for (final e in counts.entries) '${e.value} of ${e.key} stars'].join(', ')}.',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Both give: at large text on a phone the summary's words wrap
            // rather than pushing the bars past the edge.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 96),
                child: summary,
              ),
            ),
            const SizedBox(width: Insets.lg),
            Flexible(
              flex: 2,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: bars,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewCard extends ConsumerWidget {
  const _ReviewCard({
    required this.store,
    required this.app,
    required this.review,
    required this.fresh,
    required this.showStore,
  });

  final StoreKind store;
  final StoreApp app;
  final StoreReview review;

  /// Written in the week before it was read.
  final bool fresh;

  final bool showStore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final now = ref.watch(clockProvider).nowUtc();
    final low = review.rating > 0 && review.rating <= 2;
    final meta = [
      ?review.author,
      ?review.locale,
      if (review.appVersion case final version?) 'v$version',
      formatShortDay(review.createdAt, now),
    ].join(' · ');
    final title = review.title;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // Takes what the actions leave; the pill wraps under the
                  // stars rather than pushing them off a phone.
                  Expanded(
                    child: Wrap(
                      spacing: Insets.sm,
                      runSpacing: Insets.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Semantics(
                          label: '${review.rating} of 5 stars',
                          child: ExcludeSemantics(
                            child: Text(
                              formatStars(review.rating),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: low ? semantic.attention : semantic.idle,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                        ),
                        if (fresh)
                          StatusPill(label: 'New', color: semantic.unread),
                      ],
                    ),
                  ),
                  HandToSessionButton(
                    label: 'Start a session from this review',
                    dense: true,
                    title: 'Review: ${app.name}',
                    prompt: () => reviewPrompt(app, review),
                  ),
                  const SizedBox(width: Insets.xs),
                  if (!review.answered)
                    Text('Not answered', style: muted)
                  else
                    Icon(
                      AppIcons.chatCircle,
                      size: Chrome.iconAction,
                      color: scheme.onSurfaceVariant,
                      semanticLabel: 'Answered',
                    ),
                ],
              ),
              if (title != null && title.isNotEmpty) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (review.body.isNotEmpty) ...[
                const SizedBox(height: Insets.xs),
                SelectableText(review.body, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: Insets.xs),
              Row(
                children: [
                  if (showStore) ...[
                    StoreLogo(store, size: Chrome.iconAction),
                    const SizedBox(width: Insets.xs),
                  ],
                  Expanded(child: Text(meta, style: muted)),
                ],
              ),
              if (review.reply case final reply?) ...[
                const SizedBox(height: Insets.sm),
                Container(
                  padding: const EdgeInsetsDirectional.only(start: Insets.md),
                  decoration: BoxDecoration(
                    border: BorderDirectional(
                      start: BorderSide(color: scheme.outlineVariant, width: 2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      EyebrowLabel(
                        review.repliedAt == null
                            ? 'Your reply'
                            : 'Your reply · '
                                  '${formatShortDay(review.repliedAt!, now)}',
                      ),
                      const SizedBox(height: Insets.xxs),
                      Text(reply, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
