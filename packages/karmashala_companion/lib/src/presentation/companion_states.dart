/// Loading, empty and error — the three states a screen is unfinished without,
/// framing the shared Explorer cards with the app's own tokens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart' show CapabilitySet;
import 'companion_chrome.dart';

/// Draws [value] through its four states. Not `when`: a provider being retried
/// is `AsyncLoading` *carrying* its error, so `when` skeletons for ever.
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

/// The sentence to show for a thrown [error]. A [GatewayException] carries one
/// already; anything else is a bug, and a Dart type helps nobody.
String companionErrorText(Object error) => error is GatewayException
    ? error.message
    : 'Something went wrong talking to your desktop.';

/// How old the snapshot a companion screen is drawing is. A reading whose time
/// was never recorded says "age unknown" and never "just now" (§19).
String companionSnapshotAge(DateTime? receivedAt, DateTime now) =>
    receivedAt == null ? 'age unknown' : describeAge(now.difference(receivedAt));

/// What a pairing let this phone do, in words: "send prompt, approve".
String companionGrantsSentence(CapabilitySet capabilities) => capabilities
    .granted
    .map((c) => c.wire.replaceAll('_', ' '))
    .join(', ');

/// A block the size and shape of text that has not arrived yet: a title or
/// muted line at the reader's text scale, so 200% text loads 200% bones.
class _Bone extends StatelessWidget {
  const _Bone({required this.width, this.title = false});

  /// A fraction of the available width, 0–1.
  final double width;

  /// A title line rather than a muted one.
  final bool title;

  /// Faint enough to read as "not here yet" rather than as content.
  static const _alpha = 0.07;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final style = title ? density.title(theme) : density.muted(theme);
    final size = style?.fontSize ?? Insets.md;
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: width,
      child: Container(
        height: MediaQuery.textScalerOf(context).scale(size),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: _alpha),
          borderRadius: BorderRadius.circular(Insets.xs),
        ),
      ),
    );
  }
}

/// Rows the shape of the list that is loading. Deliberately still: a repeating
/// shimmer never settles, which hangs every `pumpAndSettle` in the suite.
class CompanionSkeletonList extends StatelessWidget {
  const CompanionSkeletonList({this.rows = 4, this.lines = 3, super.key});

  final int rows;

  /// How many lines a row of the real list has, so two different lists do not
  /// load into the same silhouette.
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
              const _Bone(width: 0.72, title: true),
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
/// both. Never a raw exception, a blank page, or a state with no way forward.
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
    this.tertiaryLabel,
    this.onTertiary,
    super.key,
  });

  /// A search that matched nothing. The phone filters the snapshot it holds and
  /// sends no frame, so this is a statement about that snapshot and the fields
  /// named in [searched] — never about the desktop, which was not asked.
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

  /// Picks the icon's colour out of [SemanticColors]; null is the muted default.
  final NoticeTone? tone;

  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// A third way forward, for a screen that genuinely has one. Rare on purpose:
  /// the pairing screen has it because a machine with its own address cannot be
  /// reached by either of the other two.
  final String? tertiaryLabel;
  final VoidCallback? onTertiary;

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
          constraints: const BoxConstraints(maxWidth: companionFocusedWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(Insets.lg),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colour.withValues(alpha: 0.12),
                ),
                // Sized as an illustration rather than as chrome.
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
                // A phone's empty state is the whole screen; a pane's shares it
                // with whatever is beside it and stays at the smaller step.
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
              if (tertiaryLabel != null) ...[
                const SizedBox(height: Insets.sm),
                TextButton(
                  onPressed: onTertiary,
                  child: Text(tertiaryLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Which semantic colour a notice's glyph borrows; null is the muted default.
enum NoticeTone { attention, failure, idle }

/// A refusal or failure said in place, under the thing that failed: a warning
/// glyph and the sentence, in the error colour. The one inline error style
/// every companion form draws.
class CompanionInlineError extends StatelessWidget {
  const CompanionInlineError(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final error = theme.colorScheme.error;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warningCircle, size: density.icon, color: error),
          SizedBox(width: density.glyphGap),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: error),
            ),
          ),
        ],
      ),
    );
  }
}
