import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';

import '../../explorer/application/session_context.dart';
import '../../notes/application/composer_draft.dart';
import '../application/session_providers.dart';
import '../application/session_ui_providers.dart';
import 'new_session_dialog.dart';
import 'session_destination_picker.dart';

/// Opens the new-session dialog with [prompt] filled in; the person reads it,
/// picks where it runs, and starts it — nothing starts on its own.
Future<void> startSessionWith(
  BuildContext context, {
  required String prompt,
  String? title,
  SessionDestination? destination,
}) => NewSessionDialog.show(
  context,
  firstPrompt: prompt,
  title: title,
  destination: destination,
);

/// Offers [prompt] to the focused session as an unsent draft, the way a note
/// is sent back; says so when no session is focused.
void draftInFocusedSession(
  BuildContext context,
  WidgetRef ref, {
  required String prompt,
}) {
  final sessionId = ref.read(focusedSessionIdProvider);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (sessionId == null) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('No session is open to draft this in.')),
    );
    return;
  }
  final title =
      ref.read(sessionsDataProvider).getById(sessionId)?.title ?? 'the session';
  final outcome = offerToSession(ref, sessionId: sessionId, text: prompt);
  ref.read(selectedSessionIdProvider.notifier).select(sessionId);
  messenger?.showSnackBar(
    SnackBar(content: Text(sessionOfferMessage(outcome, title))),
  );
}

/// A button offering [prompt] to an agent: a new session, or a draft in the
/// focused one. [prompt] is built only when a choice is made, and may be
/// fetched then: a failure to build it is said, and nothing is offered.
class HandToSessionButton extends ConsumerWidget {
  const HandToSessionButton({
    required this.label,
    required this.prompt,
    this.title,
    this.destination,
    this.dense = false,
    super.key,
  });

  final String label;
  final FutureOr<String> Function() prompt;
  final String? title;
  final SessionDestination? destination;

  /// An icon alone, for a row with little room.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.plusCircle, size: 16),
          onPressed: () => _withPrompt(
            context,
            (text) => startSessionWith(
              context,
              prompt: text,
              title: title,
              destination: destination,
            ),
          ),
          child: const Text('New session…'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.paperPlaneRight, size: 16),
          onPressed: ref.watch(focusedSessionIdProvider) == null
              ? null
              : () => _withPrompt(
                  context,
                  (text) => draftInFocusedSession(context, ref, prompt: text),
                ),
          child: const Text('Draft in the focused session'),
        ),
      ],
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        return dense
            ? IconButton(
                icon: const Icon(AppIcons.robot, size: 16),
                tooltip: label,
                onPressed: toggle,
              )
            : TextButton.icon(
                icon: const Icon(AppIcons.robot, size: 16),
                label: Text(label),
                onPressed: toggle,
              );
      },
    );
  }

  Future<void> _withPrompt(
    BuildContext context,
    void Function(String text) offer,
  ) async {
    final String text;
    try {
      text = await prompt();
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Could not prepare it: $error')));
      return;
    }
    if (context.mounted) offer(text);
  }
}
