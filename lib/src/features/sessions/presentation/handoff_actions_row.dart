import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/handoff_providers.dart';
import '../application/session_actions.dart';
import '../application/session_handoff_service.dart';
import '../domain/handoff_action.dart';
import 'continue_with_dialog.dart';

/// The handoff row: commit / open PR / run tests, sat above the message box.
///
/// Each button **sends its prompt verbatim into the session** through the same
/// [SessionActions.continueSession] the composer uses — there is no second write
/// path, no confirm dialog, and no status re-read afterwards. See
/// [HandoffAction] for the reasoning.
///
/// Because it sends through the composer's channel, the row appears exactly
/// where the composer can send: native sessions. Imported CLI sessions render in
/// `imported_session_view.dart`, which does not use this widget, so an inert
/// session shows no row.
///
/// The only visible machinery is a disabled state while a send is in flight, so
/// a double-click cannot queue the same prompt twice. Everything after the
/// prompt leaves the app — a dirty index, a missing upstream, a rejected push —
/// is reported by the agent in the transcript. The single error surface is a
/// snackbar for a failure that means the prompt never left the app at all (the
/// repository or agent installation is gone).
///
/// **"Continue with…" is the one entry here that is not a prompt**, and it is
/// drawn apart from the others for that reason. Commit, PR and tests are
/// sentences typed into the session that is already running; continuing
/// somewhere else starts a *different* session, with a document the user should
/// read first. It opens [ContinueWithDialog] rather than doing anything, and
/// the whole of the decision lives there.
class HandoffActionsRow extends ConsumerStatefulWidget {
  const HandoffActionsRow({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<HandoffActionsRow> createState() => _HandoffActionsRowState();
}

class _HandoffActionsRowState extends ConsumerState<HandoffActionsRow> {
  bool _sending = false;

  Future<void> _send(HandoffAction action) async {
    if (_sending) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await ref
          .read(sessionActionsProvider)
          .continueSession(widget.sessionId, action.prompt);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // `asData?.value` folds "still loading" and "the probe threw" into the same
    // null the domain reads as "could not tell" — deliberately, so a slow or
    // broken git/gh never withholds an action.
    final state = ref
        .watch(sessionHandoffStateProvider(widget.sessionId))
        .asData
        ?.value;
    final actions = handoffActionsFor(state);

    final canContinue = ref
        .watch(sessionContinuationProvider(widget.sessionId))
        .isPossible;
    if (actions.isEmpty && !canContinue) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, Insets.sm, 8, 0),
          child: Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              for (final action in actions)
                ActionChip(
                  avatar: Icon(_iconFor(action), size: 14),
                  label: Text(action.label),
                  tooltip: 'Sends “${action.prompt}”',
                  onPressed: _sending ? null : () => _send(action),
                ),
              if (canContinue)
                ActionChip(
                  avatar: const Icon(AppIcons.arrowBendDownRight, size: 14),
                  label: const Text('Continue with…'),
                  tooltip:
                      'Move this session to another agent, or fork it. '
                      'Nothing is launched until you have seen what the next '
                      'agent will be told.',
                  onPressed: _sending
                      ? null
                      : () =>
                            ContinueWithDialog.show(context, widget.sessionId),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

IconData _iconFor(HandoffAction action) => switch (action) {
  HandoffAction.commit => AppIcons.check,
  HandoffAction.pullRequest => AppIcons.gitMerge,
  HandoffAction.runTests => AppIcons.play,
};
