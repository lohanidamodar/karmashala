import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_session/resume.dart';
import '../application/unresumable_sessions.dart';

/// The rows that name a conversation their agent does not have — listed, then
/// removed or restarted. A reading, not a button: the answer is sometimes
/// *unknown*. Removing is irreversible; restarting keeps the row.
class UnresumableSessionsDialog extends ConsumerStatefulWidget {
  const UnresumableSessionsDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const UnresumableSessionsDialog(),
  );

  @override
  ConsumerState<UnresumableSessionsDialog> createState() =>
      _UnresumableSessionsDialogState();
}

class _UnresumableSessionsDialogState
    extends ConsumerState<UnresumableSessionsDialog> {
  /// Rows the user has un-ticked. Kept as exclusions rather than as a
  /// selection so a fresh reading arrives fully ticked without having to be
  /// re-selected.
  final Set<String> _excluded = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    // Once, on open — never in `build`, and never on a timer. Reading the CLI
    // stores is real work; §19's third rule is what this follows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(unresumableSessionsProvider.notifier);
      if (ref.read(unresumableSessionsProvider).hasRun) return;
      controller.refresh();
    });
  }

  List<UnresumableSession> _ticked(UnresumableReview review) => [
    for (final row in review.removable)
      if (!_excluded.contains(row.session.id)) row,
  ];

  Future<void> _restart(UnresumableSession row) async {
    setState(() => _error = null);
    try {
      await ref
          .read(unresumableSessionsProvider.notifier)
          .restart(row.session.id);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(content: Text(restartUnkeptPromiseMessage(row.session.title))),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = ref.watch(unresumableSessionsProvider);
    final controller = ref.read(unresumableSessionsProvider.notifier);
    final ticked = _ticked(review);
    // Width is chosen, height is not. Height was `min(viewport.height - 220,
    // 420)`; at 720x560 with text at 1.3x, `Expanded` got a negative height,
    // the list never laid out, and its controls left the Tab ring.
    final width = math.min(MediaQuery.sizeOf(context).width - 80, 560.0);

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.warningCircle,
        title: 'Sessions with no conversation',
        subtitle: 'Rows whose agent has no record of the conversation they '
            'name. Remove them, or start a conversation in one to keep it.',
      ),
      content: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Reading(review: review, running: controller.running),
            if (_error != null) ...[
              const SizedBox(height: Insets.sm),
              DesktopErrorBanner(_error!),
            ],
            const SizedBox(height: Insets.sm),
            Flexible(
              child: _Body(
                review: review,
                running: controller.running,
                excluded: _excluded,
                onToggle: (id) => setState(() {
                  _excluded.contains(id)
                      ? _excluded.remove(id)
                      : _excluded.add(id);
                }),
                onRestart: _restart,
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        Insets.lg,
        0,
        Insets.lg,
        Insets.md,
      ),
      actions: [
        TextButton.icon(
          onPressed: controller.running ? null : controller.refresh,
          icon: const Icon(AppIcons.arrowsClockwise),
          label: Text(review.hasRun ? 'Check again' : 'Check now'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          // Disabled at nothing ticked rather than hidden, so the count above
          // it is always the count this button acts on.
          onPressed: ticked.isEmpty
              ? null
              : () {
                  controller.remove([
                    for (final row in ticked) row.session.id,
                  ]);
                  setState(() => _excluded.clear());
                },
          child: Text(
            ticked.length == 1
                ? 'Remove 1 session'
                : 'Remove ${ticked.length} sessions',
          ),
        ),
      ],
    );
  }
}

/// The reading's own line: what it covers, and how old it is.
class _Reading extends ConsumerWidget {
  const _Reading({required this.review, required this.running});

  final UnresumableReview review;
  final bool running;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final checkedAt = review.checkedAt;
    final age = switch ((running, checkedAt)) {
      (true, _) => 'Reading the CLI stores — one pass, however many sessions.',
      (false, null) => 'Nothing has been checked yet.',
      (false, final at?) =>
        'Checked ${describeAge(ref.read(clockProvider).nowUtc().difference(at))}'
            '${review.storesUnreadable == 0 ? '' : ' — ${review.storesUnreadable} store(s) could not be read'}.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(review.summary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Insets.xs),
        Text(
          age,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.review,
    required this.running,
    required this.excluded,
    required this.onToggle,
    required this.onRestart,
  });

  final UnresumableReview review;
  final bool running;
  final Set<String> excluded;
  final void Function(String id) onToggle;
  final Future<void> Function(UnresumableSession row) onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A minimum, because these two states have no rows to give the panel a
    // height and a `Center` under `Flexible` would collapse to nothing.
    if (!review.hasRun) {
      return _Placeholder(
        child: running
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('Nothing checked.', style: theme.textTheme.bodySmall),
      );
    }
    if (review.isEmpty) {
      return _Placeholder(
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                AppIcons.checkCircle,
                size: Chrome.iconHero,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                'Every session here names a conversation its agent has.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      primary: false,
      // Takes the rows' own height inside the `Flexible` above, and scrolls
      // only once the dialog runs out of room.
      shrinkWrap: true,
      children: [
        for (final row in review.removable)
          _Row(
            row: row,
            ticked: !excluded.contains(row.session.id),
            onToggle: () => onToggle(row.session.id),
            onRestart: () => onRestart(row),
          ),
        if (review.uncertain.isNotEmpty) ...[
          const SizedBox(height: Insets.md),
          Text(
            // Named, not hidden: a row nobody could judge is the one a user
            // most needs told about, because silence would read as "kept".
            review.uncertain.length == 1
                ? 'Left alone — 1 session could not be checked'
                : 'Left alone — ${review.uncertain.length} sessions could not '
                      'be checked',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          for (final row in review.uncertain)
            _Row(row: row, ticked: null, onToggle: null, onRestart: null),
        ],
      ],
    );
  }
}

/// An empty or not-yet-run state, given a height of its own: the rows are what
/// size this panel, and a bare `Center` in the `Flexible` collapses.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 96),
    child: Center(child: child),
  );
}

/// One session. Ticked and removable, or listed and left alone.
class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.ticked,
    required this.onToggle,
    required this.onRestart,
  });

  final UnresumableSession row;

  /// Null for a row that cannot be removed, which is what hides the checkbox.
  final bool? ticked;
  final VoidCallback? onToggle;

  /// Null for a row nothing could judge — see the build method.
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tick = ticked;
    // Once the rows outgrow the dialog they are in a scroll, and a stop the
    // list has moved above the viewport is one forward Tab will not scroll back
    // to. See [RevealOnFocus].
    return RevealOnFocus(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        // Two lines and two stops: the restart verb as a subtitle button plus a
        // tappable tile was three stops a row and tall enough to overflow into
        // a scroll, after which `ensureVisible` made Tab revisit a stop.
        leading: tick == null
            ? Icon(
                AppIcons.warningCircle,
                size: Touch.icon,
                color: theme.colorScheme.onSurfaceVariant,
              )
            : Checkbox(value: tick, onChanged: (_) => onToggle?.call()),
        title: Text(
          row.session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          row.note,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Named for what it does to *this* session, and absent on a row nothing
        // could judge: `unknown` means the store was unreachable, so the
        // conversation may be there and starting a second would abandon it.
        trailing: onRestart == null
            ? null
            : IconButton(
                icon: const Icon(AppIcons.plus, size: Chrome.icon),
                tooltip: 'Start a conversation here',
                onPressed: onRestart,
              ),
      ),
    );
  }
}
