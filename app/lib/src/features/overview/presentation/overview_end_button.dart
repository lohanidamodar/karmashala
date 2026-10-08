import 'dart:async';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_state_providers.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_resume.dart';

/// Whether the pointer is over a card or row, or the keyboard is in it: what
/// shows its [OverviewEndButton] under a mouse.
class OverviewHoverScope extends StatefulWidget {
  const OverviewHoverScope({required this.child, super.key});

  final Widget child;

  /// Whether the card around [context] is hovered or holds focus; false with
  /// no scope.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_HoverInherited>()
          ?.notifier
          ?.value ??
      false;

  @override
  State<OverviewHoverScope> createState() => _OverviewHoverScopeState();
}

class _OverviewHoverScopeState extends State<OverviewHoverScope> {
  final _hovered = ValueNotifier(false);
  final _focused = ValueNotifier(false);
  late final _either = _Either(_hovered, _focused);

  @override
  void dispose() {
    _either.dispose();
    _hovered.dispose();
    _focused.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _hovered.value = true,
    onExit: (_) => _hovered.value = false,
    // Not a stop of its own: it only hears a descendant take the keys.
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => _focused.value = focused,
      child: _HoverInherited(notifier: _either, child: widget.child),
    ),
  );
}

/// True while either of two flags is.
class _Either extends ValueNotifier<bool> {
  _Either(this._a, this._b) : super(false) {
    _a.addListener(_update);
    _b.addListener(_update);
  }

  final ValueNotifier<bool> _a;
  final ValueNotifier<bool> _b;

  void _update() => value = _a.value || _b.value;

  @override
  void dispose() {
    _a.removeListener(_update);
    _b.removeListener(_update);
    super.dispose();
  }
}

class _HoverInherited extends InheritedNotifier<ValueNotifier<bool>> {
  const _HoverInherited({required super.notifier, required super.child});
}

/// What ending [card] now would lose, in one sentence for the confirm; null
/// only for a session known to be idle, which ends at once. The shared rule
/// ([endSessionWarning]) decides, with the board's own reading on top.
String? overviewEndWarning(WidgetRef ref, OverviewCard card) {
  const stays = 'The conversation stays.';
  final waiting =
      card.state == AgentState.needsYou ||
      ref.read(sessionActivityLookupProvider)(card.id) ==
          AgentActivityStatus.awaitingApproval ||
      ref.read(needsYouProvider).containsKey(card.id);
  if (waiting) {
    return 'It is waiting for you, and its question is dropped. $stays';
  }
  if (card.state == AgentState.working || card.state == AgentState.quiet) {
    return 'It is mid-turn: that turn is lost. $stays';
  }
  if (endSessionWarning(ref, card.id) != null) {
    return 'Karmashala cannot tell whether it is mid-turn; a turn in flight '
        'is lost. $stays';
  }
  return null;
}

/// **End**, from a card: through [endSessionProcess], the verb the status
/// line's Stop and the session rows' End share. A session working or waiting
/// on the person asks first, in one line, as the rows' End does; an idle one
/// ends at once with Undo, which resumes it here — its conversation is kept,
/// so resuming is cheap.
Future<void> endFromDashboard(
  BuildContext context,
  WidgetRef ref,
  OverviewCard card,
) async {
  final id = card.id;
  final title = card.entry.title;
  final warning = overviewEndWarning(ref, card);
  final asks = warning != null;
  if (warning != null) {
    final confirmed = await showConfirmDialog(
      context,
      title: 'End "$title"?',
      message: warning,
      confirmLabel: 'End session',
    );
    if (!confirmed || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  // Read now: the card is gone from here once its session ends.
  final resumer = ref.read(overviewResumerProvider);
  final focus = ref.read(overviewFocusProvider.notifier);
  String say;
  SnackBarAction? undo;
  try {
    if (!await endSessionProcess(ref, id)) {
      say = 'Nothing is running that session, so there is nothing to end.';
    } else {
      say = 'Ended "$title"';
      if (!asks) {
        undo = SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(() async {
            focus.peek(id);
            final result = await resumer.resume(id);
            if (result.message case final said?) {
              messenger?.showSnackBar(SnackBar(content: Text(said)));
            }
          }()),
        );
      }
    }
  } on Object catch (error) {
    say =
        'Could not end that session: '
        '${error is StateError ? error.message : error}';
  }
  messenger?.showSnackBar(SnackBar(content: Text(say), action: undo));
}

/// A card's quick **End**, beside its ⋯: on a live session only. Under a
/// thumb it is always there; under a mouse it shows while the card is
/// hovered or holds the keys, and keeps its room so nothing shifts.
class OverviewEndButton extends ConsumerWidget {
  const OverviewEndButton({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (card.state == AgentState.ended) return const SizedBox.shrink();
    if (!sessionHasLiveProcess(ref, card.id)) return const SizedBox.shrink();
    final density = UiDensity.of(context);
    final shown = density.isTouch || OverviewHoverScope.of(context);
    final button = IconButton(
      key: ValueKey('overview-end:${card.id}'),
      tooltip: 'End session',
      visualDensity: density.controlDensity,
      padding: EdgeInsets.zero,
      constraints: density.iconConstraints(Chrome.control),
      iconSize: density.iconSize(Chrome.iconSmall),
      icon: const Icon(AppIcons.stop),
      onPressed: () => unawaited(endFromDashboard(context, ref, card)),
    );
    return AnimatedOpacity(
      key: ValueKey('overview-end-slot:${card.id}'),
      opacity: shown ? 1 : 0,
      duration: Motion.of(context).fast,
      // Hidden, a click passes it by; Tab still reaches it, which shows it.
      child: IgnorePointer(ignoring: !shown, child: button),
    );
  }
}
