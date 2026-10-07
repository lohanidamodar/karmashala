import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../application/store_groups.dart';
import 'store_badges.dart';
import 'store_logo.dart';
import 'stores_format.dart';

/// Whether [release] is history: replaced, expired or removed. Shown only
/// when asked for.
bool _isHistory(StoreRelease release) => const {
  ReleaseState.superseded,
  ReleaseState.expired,
  ReleaseState.removed,
}.contains(release.state);

/// What is moving or stuck, then what is out, then the rest: the store's
/// order kept within each.
List<StoreRelease> _currentFirst(List<StoreRelease> releases) {
  int rank(StoreRelease release) {
    final state = release.state;
    if (state.needsAttention || state.inFlight) return 0;
    if (state == ReleaseState.live || state == ReleaseState.testing) return 1;
    return 2;
  }

  return [
    for (var r = 0; r < 3; r++)
      ...releases.where((release) => rank(release) == r),
  ];
}

/// One store's releases, a block per track — public first — each with what
/// is current on it; replaced and expired releases fold away under a count.
class StoreReleasesCard extends StatefulWidget {
  const StoreReleasesCard({required this.entry, super.key});

  final StoreEntry entry;

  @override
  State<StoreReleasesCard> createState() => _StoreReleasesCardState();
}

class _StoreReleasesCardState extends State<StoreReleasesCard> {
  bool _history = false;

  /// Kept in the route's [PageStorage] rather than only here: the detail
  /// moves this card to another column when it crosses its wide breakpoint,
  /// which builds a new State, and an opened history should stay open.
  String get _historyId =>
      'store-releases-history:'
      '${widget.entry.app.store.name}:${widget.entry.app.id}';

  @override
  void initState() {
    super.initState();
    _history =
        PageStorage.maybeOf(context)?.readState(context, identifier: _historyId)
            as bool? ??
        false;
  }

  void _toggleHistory() {
    setState(() => _history = !_history);
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _history, identifier: _historyId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final reading = widget.entry.snapshot?.releases;
    final Widget body;
    if (reading == null) {
      body = Text('Not read yet. Refresh to read it.', style: muted);
    } else if (reading case final ReadingMissing<List<StoreRelease>> missing) {
      body = MissingReadingLine(what: 'Releases', reading: missing);
    } else {
      final all = reading.valueOrNull ?? const <StoreRelease>[];
      final tracks = <String, List<StoreRelease>>{};
      for (final release in all) {
        if (_history || !_isHistory(release)) {
          tracks.putIfAbsent(release.track, () => []).add(release);
        }
      }
      final ordered = [
        ...tracks.keys.where(isPublicTrack),
        ...tracks.keys.where((track) => !isPublicTrack(track)),
      ];
      final hidden = all.where(_isHistory).length;
      body = all.isEmpty
          ? Text('No releases on any track yet.', style: muted)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ordered.isEmpty)
                  Text('Nothing current on any track.', style: muted),
                for (final (i, track) in ordered.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : Insets.md),
                    child: _Track(
                      track: track,
                      releases: _currentFirst(tracks[track]!),
                    ),
                  ),
                if (hidden > 0)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsets.only(top: Insets.sm),
                      child: TextButton.icon(
                        onPressed: _toggleHistory,
                        icon: Icon(
                          _history ? AppIcons.caretUp : AppIcons.caretDown,
                          size: Chrome.iconAction,
                        ),
                        label: Text(
                          _history
                              ? 'Hide earlier releases'
                              : 'Show $hidden earlier '
                                    '${hidden == 1 ? 'release' : 'releases'}',
                        ),
                      ),
                    ),
                  ),
              ],
            );
    }
    return StoreBlock(store: widget.entry.app.store, child: body);
  }
}

/// A bordered block headed by its store's name.
class StoreBlock extends StatelessWidget {
  const StoreBlock({required this.store, required this.child, super.key});

  final StoreKind store;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
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
            Semantics(
              header: true,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: StoreLogo.named(
                  store,
                  size: Chrome.iconTitle,
                  color: scheme.onSurface,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Insets.sm),
            child,
          ],
        ),
      ),
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.track, required this.releases});

  final String track;
  final List<StoreRelease> releases;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          formatTrack(track),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.xs),
        for (final release in releases) _ReleaseRow(release: release),
      ],
    );
  }
}

class _ReleaseRow extends ConsumerWidget {
  const _ReleaseRow({required this.release});

  final StoreRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final now = ref.watch(clockProvider).nowUtc();
    final fraction = release.rolloutFraction;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: MediaQuery.textScalerOf(context).scale(88),
            ),
            child: Text(
              formatVersion(release),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          ReleaseStatePill(release: release),
          if (fraction != null) RolloutBar(fraction: fraction),
          if (release.date case final date?)
            Text(formatShortDay(date, now), style: muted),
        ],
      ),
    );
  }
}
