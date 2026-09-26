import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which session's **conversation** a workspace group keeps mounted, given what
/// it held before. Asked for by the group leaving its terminal; let go of once
/// the group is about some other session while on its terminal.
String? nextMountedConversation({
  required String? current,
  required String? sessionId,
  required bool onTerminal,
}) {
  if (!onTerminal && sessionId != null) return sessionId;
  return current == sessionId ? current : null;
}

/// The conversation one workspace group keeps mounted, or null. Built only once
/// asked for: an `IndexedStack` mounts every child, transcript and all.
///
/// Kept here rather than in the group's `State`, so a group rebuilt under a new
/// element keeps the conversation it had.
class WorkspaceGroupConversation extends Notifier<String?> {
  WorkspaceGroupConversation(this.groupId);

  final String groupId;

  @override
  String? build() => null;

  /// Applies [nextMountedConversation]. Not callable while a widget builds —
  /// the group settles it after the frame.
  void settle({required String? sessionId, required bool onTerminal}) {
    final next = nextMountedConversation(
      current: state,
      sessionId: sessionId,
      onTerminal: onTerminal,
    );
    if (next != state) state = next;
  }
}

final workspaceGroupConversationProvider = NotifierProvider.autoDispose
    .family<WorkspaceGroupConversation, String?, String>(
      WorkspaceGroupConversation.new,
    );
