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
    '(Karmashala: the person has let this session operate Karmashala — its '
    'tools that act, such as starting or sending to sessions, running '
    'terminals, restoring checkpoints and driving devices, now run for you.)';

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
          'Its agent will be able to act through Karmashala, not only read it: '
          'start, send to and end sessions, run commands in terminals, '
          'restore checkpoints, add projects and worktrees, drive devices and '
          'the browser, and run builds. Other sessions are not affected, and '
          'you can take it back here at any time.',
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

/// **Whether this session's agent may operate Karmashala** (owner,
/// 2026-10-01): off, it reads — sessions, transcripts, terminals, devices —
/// and keeps its own todos, notes and verification records; on, the tools
/// that act run for it too. Per session, and the person's alone to change.
class OperatorChip extends ConsumerWidget {
  const OperatorChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watchSession(sessionId);
    final row = ref.read(sessionsDataProvider).getById(sessionId);
    if (row == null) return const SizedBox.shrink();
    final on = row.operatorGranted;
    return Tooltip(
      message: on
          ? 'This agent may operate Karmashala: start, send to and end '
                'sessions, run terminals, restore checkpoints, drive devices '
                'and builds. Click to take it back.'
          : 'This agent reads Karmashala but cannot act on it. Click to let '
                'it operate Karmashala — or start a message with /operator.',
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () =>
            setOperatorGrant(context, ref, sessionId, granted: !on),
        child: PickerFace(
          icon: on ? AppIcons.robot : AppIcons.shield,
          label: on ? 'Operates' : 'Read-only',
          qualifiers: const ['Karmashala'],
        ),
      ),
    );
  }
}
