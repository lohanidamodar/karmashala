import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
import '../../sessions/domain/unkept_promise.dart';
import '../application/unresumable_sessions.dart';

/// The rows that name a conversation their agent does not have — listed, then
/// removed or restarted.
///
/// **Why a review and not a button.** The ask was "a quick button that will
/// remove all those", and a button alone could not be honest: the only way to
/// know a row is dead is to ask the CLI, the answer is sometimes *unknown* (an
/// unreachable WSL share, a store in a format nobody reads), and a session
/// started a minute ago is indistinguishable from a dead one until the agent
/// writes its transcript. So the reading is shown before it is acted on: what
/// it found, what it could not judge, and how old it is. §19's rules, applied
/// to housekeeping.
///
/// **Two verbs, because they are worth different things.** Removing is quick
/// and irreversible. Restarting keeps the row — its title, its age, its
/// lineage, its place in the tree — and simply makes the promise again, which
/// for a session the user still recognises is the better answer. Neither is the
/// other's fallback.
///
/// **Sized to the viewport**, not to the desktop: the panel is 560px of list at
/// 1440x900 and fills a 390x844 phone without either dimension overflowing.
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
    // **Width is chosen, height is not.**
    //
    // Material insets a dialog by 40px a side, so 560 is comfortable on a
    // desktop and a 390px phone gets what it has. Height had a matching
    // `min(viewport.height - 220, 420)` and that was a bug the window matrix
    // caught: 220 is a guess about the title and the button row, and at
    // 720x560 with Windows' text at 1.3x those grow past it. The content's
    // `Expanded` then got a negative height, the list never laid out, and
    // every control inside it silently left the Tab ring — a panel you could
    // not reach the checkboxes of, reported as a focus finding rather than as
    // the layout error it was.
    //
    // So the height is the dialog's own: `Column(mainAxisSize: min)` with the
    // list `Flexible` and shrink-wrapping takes exactly what the rows need, up
    // to whatever `Dialog` allows for this viewport, and scrolls beyond that.
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

/// An empty or not-yet-run state, given a height of its own.
///
/// The rows are what size this panel; with none, a bare `Center` inside the
/// content's `Flexible` collapses and the message disappears.
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
    return ListTile(
      contentPadding: EdgeInsets.zero,
      // Two lines and two stops, deliberately.
      //
      // The first version put the restart verb in the subtitle as a text
      // button and gave the tile its own `onTap` as well. Both were wrong at
      // 720x560 with Windows' text turned up to 1.3x, and the window matrix
      // said so: three focus stops per row where two do the same thing, and a
      // tile tall enough that two rows and a section header overflowed the
      // panel into a scroll — after which Tab's `ensureVisible` moved the list
      // under the traversal and the ring revisited a stop it had already had.
      //
      // So the checkbox is the only thing that ticks the row, and the verb is
      // a trailing glyph inside the tile's own box: shorter, one stop, and it
      // still reads at 390px.
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
      // The row's own way out, and the one that keeps it. Named for what it
      // does to *this* session rather than "new session", which is the advice
      // `resumeMissingConversationMessage` already gives and which loses the
      // row.
      //
      // **Absent on a row nothing could judge**, which is the same rule as the
      // missing checkbox and matters more. An `unknown` verdict means the
      // store was unreachable, so the conversation may well be there and
      // resumable once the distribution is running — and starting a second one
      // over the row would abandon it. A row we cannot speak for is offered
      // neither verb.
      trailing: onRestart == null
          ? null
          : IconButton(
              icon: const Icon(AppIcons.plus, size: Chrome.icon),
              tooltip: 'Start a conversation here',
              onPressed: onRestart,
            ),
    );
  }
}
