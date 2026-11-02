import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';

/// What a message starts with to let its session operate Karmashala: typed,
/// it is the person's own act, so it asks nothing further.
const String kOperatorCommand = '/operator';

/// [text] without a leading [kOperatorCommand], or null when it does not start
/// with one. Empty when the command was the whole message.
String? textAfterOperatorCommand(String text) {
  final match = RegExp(r'^\s*/operator(?=\s|$)').firstMatch(text);
  if (match == null) return null;
  return text.substring(match.end).trim();
}

/// The line the agent reads ahead of a message that granted it: the tools
/// that were refused a moment ago now run, and it should know without trying.
const String kOperatorGrantedNote =
    '(Karmashala: the person has let this session operate Karmashala — you '
    'may now start, message and end other sessions and agents.)';

/// What a session with the grant may do, in every place that describes it.
const String kOperatorGrantedHelp =
    'This agent may start, message and end other sessions and agents.';

/// What a session without the grant may not do. Not a sandbox, so it says so.
const String kOperatorNotGrantedHelp =
    'This agent cannot start, message or end other sessions and agents. This '
    'is not a sandbox: it can still use devices, the browser, builds and its '
    'shell.';

/// Lets session [sessionId]'s agent operate Karmashala, or takes it back.
/// Turning it on from the chip asks first ([confirm]); `/operator` does not,
/// since typing it is the asking. Returns whether it was changed.
Future<bool> setOperatorGrant(
  BuildContext context,
  WidgetRef ref,
  String sessionId, {
  required bool granted,
  bool confirm = true,
}) async {
  final row = ref.read(sessionsDataProvider).getById(sessionId);
  if (row == null) return false;
  if (row.operatorGranted == granted) return true;
  if (granted && confirm) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Let "${row.title}" operate Karmashala?'),
        content: const Text(
          'Its agent will be able to start, message and end other sessions '
          'and agents. This switch is not a sandbox: without it, an agent can '
          'still use devices, the browser, builds and its shell. You can take '
          'it back here at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Let it operate'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
  }
  ref.read(sessionsDataProvider).setOperatorGranted(sessionId, granted);
  ref.publishSessionChange(
    SessionChange(
      sessionId: sessionId,
      kinds: const {SessionChangeKind.settings},
    ),
  );
  return true;
}

/// **Whether this session's agent may operate Karmashala**: on, it may start,
/// message and end other sessions and agents (owner, 2026-11-02). Per session,
/// and the person's alone to change. Off is not a sandbox.
class OperatorChip extends ConsumerWidget {
  const OperatorChip({
    required this.sessionId,
    this.onlyWhenOn = false,
    super.key,
  });

  final String sessionId;

  /// The session bar's badge: nothing while off, the default, which is
  /// granted from ⋯ instead.
  final bool onlyWhenOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watchSession(sessionId);
    final row = ref.read(sessionsDataProvider).getById(sessionId);
    if (row == null) return const SizedBox.shrink();
    final on = row.operatorGranted;
    if (onlyWhenOn && !on) return const SizedBox.shrink();
    return Tooltip(
      key: onlyWhenOn ? const ValueKey('session-operator-badge') : null,
      message: on
          ? '$kOperatorGrantedHelp Click to take it back.'
          : '$kOperatorNotGrantedHelp Click to let it operate Karmashala — or '
                'start a message with /operator.',
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => setOperatorGrant(context, ref, sessionId, granted: !on),
        child: PickerFace(
          icon: AppIcons.robot,
          label: on ? 'Operates' : 'Not operating',
          // The badge keeps to its word: the tooltip says what it operates.
          qualifiers: onlyWhenOn ? const [] : const ['Karmashala'],
        ),
      ),
    );
  }
}
