/// Loading, empty and error — the three states a screen is unfinished without.
///
/// Companion scaffolding rather than a second widget vocabulary: the shapes
/// here frame the shared Explorer cards, and every colour, radius and spacing
/// comes from the app's own tokens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
import 'package:karmashala_remote/companion.dart';

/// Draws [value] through its four states.
///
/// **Not `AsyncValue.when`**, and that is the point. Riverpod 3 retries a
/// provider that failed, and while it retries the state is `AsyncLoading`
/// *carrying* the error — so `when` takes its loading branch and the screen
/// sits on a skeleton for ever instead of ever saying what went wrong. This
/// asks the three questions in the order a user cares about: is there
/// anything to show, did the first attempt fail, or has it simply not
/// answered yet. A retry that fails while data is already on screen leaves the
/// data up, which is also the right answer.
Widget companionAsync<T>(
  AsyncValue<T> value, {
  required Widget Function(T data) data,
  required Widget Function(Object error) error,
  required Widget Function() loading,
}) {
  if (value.hasValue) return data(value.requireValue);
  final failure = value.error;
  if (failure != null) return error(failure);
  return loading();
}

/// The sentence to show for a thrown [error].
///
/// A [GatewayException] already carries a user-fit sentence written by the
/// layer that knew what went wrong. Anything else is a bug, and printing a
/// Dart type at someone holding a phone tells them nothing they can act on.
String companionErrorText(Object error) => error is GatewayException
    ? error.message
    : 'Something went wrong talking to your desktop.';

/// How old the snapshot a companion screen is drawing is, in the words the
/// rest of the app uses for an age.
///
/// §19, in one function: a reading whose time was never recorded reads
/// **"age unknown"** and never "just now". The two are not the same claim, and
/// the second one is the confident false statement the rule exists to delete.
String companionSnapshotAge(DateTime? receivedAt, DateTime now) =>
    receivedAt == null ? 'age unknown' : describeAge(now.difference(receivedAt));

/// A block the size and shape of text that has not arrived yet.
class _Bone extends StatelessWidget {
  const _Bone({required this.width, this.height = 12});

  /// A fraction of the available width, 0–1.
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    alignment: Alignment.centerLeft,
    widthFactor: width,
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(Insets.xs),
      ),
    ),
  );
}

/// Rows the shape of the list that is loading.
///
/// Deliberately still. A repeating shimmer never settles, which hangs every
/// `pumpAndSettle` in the suite, and the silhouette alone already says "cards
/// are coming" — which a spinner never does.
class CompanionSkeletonList extends StatelessWidget {
  const CompanionSkeletonList({this.rows = 4, this.lines = 3, super.key});

  final int rows;

  /// How many lines a row of the real list has — three for a session card,
  /// two for a project row — so the two lists do not load into one silhouette.
  final int lines;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: ExcludeSemantics(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        itemCount: rows,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.md,
            Insets.lg,
            Insets.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Bone(width: 0.34),
              const SizedBox(height: Insets.sm),
              const _Bone(width: 0.72, height: 14),
              if (lines > 2) ...[
                const SizedBox(height: Insets.sm),
                const _Bone(width: 0.5),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// A screen with nothing on it yet, or one that failed — the same shape for
/// both, so the app never has two ways of saying "not right now".
///
/// [title] names the situation, [body] explains it in a sentence or two, and
/// the buttons are what to do about it. Never a raw exception, never a blank
/// page, and never a state with no way forward.
class CompanionNotice extends StatelessWidget {
  const CompanionNotice({
    required this.icon,
    required this.title,
    required this.body,
    this.tone,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    super.key,
  });

  /// A search that matched nothing: what was searched, and how old the thing
  /// it was searched over is.
  ///
  /// Both halves are load-bearing. The phone filters the snapshot it already
  /// holds and sends no frame, so "nothing matches" is a statement about that
  /// snapshot and about the four fields named in [searched] — never about the
  /// desktop, which was not asked.
  factory CompanionNotice.noMatch({
    required String query,
    required String searched,
    required String age,
    required VoidCallback onClear,
    Key? key,
  }) => CompanionNotice(
    key: key,
    icon: AppIcons.magnifyingGlass,
    title: 'No match for "$query"',
    body:
        'Searched $searched in the snapshot this phone holds — $age. '
        'Your desktop was not asked.',
    actionLabel: 'Clear search',
    onAction: onClear,
  );

  /// The error flavour: plain words and a retry.
  factory CompanionNotice.failure({
    required Object error,
    required VoidCallback onRetry,
    Key? key,
  }) => CompanionNotice(
    key: key,
    icon: AppIcons.warningCircle,
    title: 'That did not work',
    body: companionErrorText(error),
    tone: NoticeTone.failure,
    actionLabel: 'Try again',
    onAction: onRetry,
  );

  final IconData icon;
  final String title;
  final String body;

  /// Picks the icon's colour out of [SemanticColors]. Null is the muted
  /// default — most empty states are not a problem.
  final NoticeTone? tone;

  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final colour = switch (tone) {
      null => scheme.onSurfaceVariant,
      NoticeTone.attention => semantic.attention,
      NoticeTone.failure => semantic.failure,
      NoticeTone.idle => semantic.idle,
    };
    return Center(
      // Scrollable so the state survives a small screen at 200% text.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(Insets.lg),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colour.withValues(alpha: 0.12),
                ),
                // The one picture on a screen with nothing else on it, so it
                // is sized as an illustration rather than as chrome.
                child: Icon(
                  icon,
                  size: density.isTouch ? Touch.iconHero : Chrome.iconHero,
                  color: colour,
                ),
              ),
              const SizedBox(height: Insets.xl),
              Text(
                title,
                textAlign: TextAlign.center,
                // A phone's empty state is the whole screen and its title is
                // the only display line on it; a pane's shares the pane with
                // whatever is beside it, and stays at the smaller step.
                style: density.isTouch
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.titleMedium,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: Insets.xl),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
              if (secondaryLabel != null) ...[
                const SizedBox(height: Insets.sm),
                TextButton(
                  onPressed: onSecondary,
                  child: Text(secondaryLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Which semantic colour a notice's glyph borrows. Null — the common case —
/// is the muted default: most empty states are not a problem.
enum NoticeTone { attention, failure, idle }
