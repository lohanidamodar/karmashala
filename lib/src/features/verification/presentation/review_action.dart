import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../application/review_session_service.dart';

/// The one control that starts an independent review. One widget because the
/// interesting part is the refusal: [ReviewOffer.refusal] is never null when
/// the button is dead, and there is no confirmation step to write twice.
class ReviewAction extends ConsumerStatefulWidget {
  const ReviewAction({
    required this.sessionId,
    this.claim,
    this.compact = false,
    this.builder,
    super.key,
  });

  final String sessionId;

  /// What the work claims to do, in the words it was claimed in. Null renders
  /// as "not recorded" in the brief rather than being invented here.
  final String? claim;

  /// Draw for a narrow column: shorter labels, same behaviour.
  final bool compact;

  /// Draw this control in the host's own shape; only the rectangle moves, the
  /// decision stays here.
  final ReviewActionBuilder? builder;

  @override
  ConsumerState<ReviewAction> createState() => _ReviewActionState();
}

/// Draws the review control from [ReviewActionPresentation].
typedef ReviewActionBuilder =
    Widget Function(BuildContext context, ReviewActionPresentation offer);

/// What the review control says and does right now — everything a host needs to
/// draw its own shape, and nothing that starts a review except [onPressed].
class ReviewActionPresentation {
  const ReviewActionPresentation({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  /// The default words, for a host with none of its own.
  final String label;

  /// Why it cannot be pressed, or what pressing it will do. Never empty.
  final String tooltip;

  /// Null when nobody can be asked, or while a press is already in flight.
  final VoidCallback? onPressed;
}

class _ReviewActionState extends ConsumerState<ReviewAction> {
  bool _busy = false;

  Future<void> _start(ReviewTarget target) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(reviewSessionServiceProvider)
          .startReview(
            sessionId: widget.sessionId,
            targetInstallationId: target.installation.id,
            claim: widget.claim,
          );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${target.agentName} is reading the diff. Its verdict is recorded '
            'against this work, so it lands here rather than in its own '
            'conversation.',
          ),
        ),
      );
    } on Object catch (error) {
      // Every failure here is one the user can act on, so it is said.
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One press when there is one answer, a menu when there is a real choice.
  Future<void> _press(
    List<ReviewTarget> usable,
    ReviewTarget? preferred,
  ) async {
    if (usable.length == 1) return _start(usable.single);
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return _start(usable.first);
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final chosen = await showMenu<ReviewTarget>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      // First entry is the one worth pressing: a different model, if any.
      items: [
        for (final target in [
          ?preferred,
          ...usable.where((t) => t != preferred),
        ])
          DesktopMenuDetailItem<ReviewTarget>(
            value: target,
            label: target.agentName,
            icon: AppIcons.robot,
            // The reason to pick one reviewer over another: not behind a hover.
            detail: _tooltipFor(target),
            detailMaxLines: 3,
          ),
      ],
    );
    if (chosen != null) await _start(chosen);
  }

  /// What pressing this will do, in the permission carry's own words.
  String _tooltipFor(ReviewTarget target) => [
    if (target.isSameAgent)
      'Another ${target.agentName} installation — a different session, so the '
          'verdict counts as independent, but the same model reading its own '
          'kind of mistake.',
    target.permission.summary,
  ].join(' ');

  @override
  Widget build(BuildContext context) {
    final offer = ref.watch(sessionReviewOfferProvider(widget.sessionId));
    final usable = [
      for (final target in offer.targets)
        if (target.canReview) target,
    ];
    final only = usable.length == 1 ? usable.single : null;
    final presentation = ReviewActionPresentation(
      label: _label(only),
      tooltip: offer.isPossible
          ? (only == null
                ? 'Ask another agent to read this diff and record a verdict.'
                : _tooltipFor(only))
          // Never null when the button is dead — the reason is the point.
          : offer.refusal ?? 'No other agent can be asked to check this work.',
      onPressed: offer.isPossible && !_busy
          ? () => _press(usable, offer.preferred)
          : null,
    );
    final builder = widget.builder;
    if (builder != null) return builder(context, presentation);
    return Tooltip(
      message: presentation.tooltip,
      child: OutlinedButton.icon(
        onPressed: presentation.onPressed,
        icon: const Icon(AppIcons.listMagnifyingGlass, size: Chrome.iconSmall),
        label: Text(presentation.label),
      ),
    );
  }

  String _label(ReviewTarget? only) {
    if (only == null) {
      return widget.compact ? 'Check' : 'Have another agent check this';
    }
    return widget.compact
        ? 'Check (${only.agentName})'
        : 'Have ${only.agentName} check this';
  }
}
