import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/review_session_service.dart';

/// The one control that starts an independent review, wherever a verdict is
/// shown.
///
/// One widget rather than a button per surface, because the interesting part is
/// not the button — it is the **refusal**. This control is disabled far more
/// often than it is pressed (one agent installed, an agent that takes no
/// opening prompt, a session already two spawns deep), and each surface writing
/// its own version of "greyed out" is how a machine with one CLI on it comes to
/// look like a broken feature. Here there is exactly one place where a reason
/// becomes a tooltip, and [ReviewOffer.refusal] is never null when the button
/// is dead.
///
/// **No confirmation step**, unlike the handoff dialog, and the difference is
/// principled rather than a shortcut: a handoff can carry a permission mode
/// *across* to another agent, so the user has to read what it will do before it
/// happens. A review is capped by `carryReviewPermission` and can only ever be
/// less permissive than the session it checks, so there is nothing a
/// confirmation would protect against. The cap's own sentence is the tooltip.
///
/// What it does guarantee is narrower and worth stating: **an agent starts on a
/// press and on nothing else.** Drawing this control, or watching the offer
/// behind it, starts nothing; and where there is a real choice of reviewer the
/// press opens a menu, so a stray click cannot pick one for you.
class ReviewAction extends ConsumerStatefulWidget {
  const ReviewAction({
    required this.sessionId,
    this.claim,
    this.compact = false,
    this.builder,
    super.key,
  });

  /// The session whose work is to be checked.
  final String sessionId;

  /// What the work claims to do, in the words it was claimed in — a fan-out
  /// prompt, a user's own sentence. Null renders as "not recorded" in the
  /// brief rather than being invented here.
  final String? claim;

  /// Draw for a narrow column: shorter labels, same behaviour.
  final bool compact;

  /// Draw this control in the host's own shape instead of the default button.
  ///
  /// The decision stays here — who can be asked, what the refusal says, one
  /// press or a menu — and only the rectangle moves. The delivery strip needs
  /// it because that row spent a redesign making every control the same pill
  /// (see `_BarAction`), and an `OutlinedButton` dropped into it would be the
  /// fourth shape that redesign removed. A second copy of the *logic* is what
  /// this widget's doc exists to prevent; a second copy of the padding is not.
  final ReviewActionBuilder? builder;

  @override
  ConsumerState<ReviewAction> createState() => _ReviewActionState();
}

/// Draws the review control from [ReviewActionPresentation].
typedef ReviewActionBuilder =
    Widget Function(BuildContext context, ReviewActionPresentation offer);

/// What the review control says and does right now.
///
/// Everything a host needs to draw its own shape, and nothing it could use to
/// start a review by another route: [onPressed] is the only way in, and it is
/// the same callback the default button carries.
class ReviewActionPresentation {
  const ReviewActionPresentation({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  /// The default words, for a host with none of its own.
  final String label;

  /// Why it cannot be pressed, or what pressing it will do. Never empty — the
  /// refusal is the whole point of the control when it is dead.
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
      // Every failure here is one the user can act on — no second agent, an
      // agent that was uninstalled since the menu was built, a depth cap — so
      // it is said rather than logged.
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One press when there is one answer, a menu when there is a real choice.
  ///
  /// The doc's "one click" is the case that matters — two agents installed, one
  /// of them yours — and a menu of one would be a click spent confirming
  /// something the app already knew.
  Future<void> _press(List<ReviewTarget> usable, ReviewTarget? preferred) async {
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
      // Ordered so the first entry is the one worth pressing: a different
      // model, where there is one.
      items: [
        for (final target in [
          ?preferred,
          ...usable.where((t) => t != preferred),
        ])
          PopupMenuItem<ReviewTarget>(
            value: target,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(target.agentName),
              subtitle: Text(
                _tooltipFor(target),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
    if (chosen != null) await _start(chosen);
  }

  /// What pressing this will actually do, in the words the permission carry
  /// uses — plus the one thing a second installation of the same agent does not
  /// buy you.
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
          // Never null when the button is dead: the reason is the whole point
          // of the control in this state.
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
