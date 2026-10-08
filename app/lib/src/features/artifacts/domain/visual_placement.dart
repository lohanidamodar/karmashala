import 'package:karmashala_artifacts/karmashala_artifacts.dart';

import '../../sessions/presentation/chat_transcript.dart';

/// Which agent row each visual hangs under, by message index; those whose
/// turn has no agent words yet, drawn at the end of the conversation; and
/// those older than every message held, which belong to earlier pages.
class VisualPlacement {
  const VisualPlacement(this.byOrdinal, this.trailing, this.earlier);

  static const empty = VisualPlacement({}, [], []);

  final Map<int, List<String>> byOrdinal;
  final List<String> trailing;
  final List<String> earlier;

  /// What tells two placements apart, for caching what is built from one.
  String get key => [
    for (final e in byOrdinal.entries) '${e.key}:${e.value.join(',')}',
    't:${trailing.join(',')}',
    'e:${earlier.join(',')}',
  ].join(';');
}

/// Places each visual where its agent called `visualize`. The call's own
/// tool row, found by the id its answer names, is the transcript position —
/// for a terminal session as for a chat one; without it, the last message
/// written before the visual was. From there it hangs under the agent's
/// words just before, in the same turn, else the first after; a turn with
/// none yet draws it at the end.
VisualPlacement placeVisuals(
  List<ChatMessage> messages,
  List<SessionVisual> visuals,
) {
  if (visuals.isEmpty) return VisualPlacement.empty;
  final byOrdinal = <int, List<String>>{};
  final trailing = <String>[];
  final earlier = <String>[];
  for (final visual in visuals) {
    final anchor = _callOf(messages, visual.id) ?? _timeOf(messages, visual);
    if (anchor == null) {
      final firstTimed = messages.where((m) => m.at != null).firstOrNull?.at;
      if (firstTimed != null && visual.createdAt.isBefore(firstTimed)) {
        earlier.add(visual.id);
      } else {
        trailing.add(visual.id);
      }
      continue;
    }
    int? row;
    for (var i = anchor; i >= 0; i--) {
      final role = messages[i].role;
      if (role == 'agent') {
        row = i;
        break;
      }
      if (role == 'user') break;
    }
    if (row == null) {
      for (var i = anchor + 1; i < messages.length; i++) {
        final role = messages[i].role;
        if (role == 'user') break;
        if (role == 'agent') {
          row = i;
          break;
        }
      }
    }
    if (row == null) {
      final later = messages.skip(anchor + 1).any((m) => m.role == 'user');
      // A finished turn with no words at all keeps it at its call's turn
      // end rather than below every later turn.
      if (later) {
        (byOrdinal[anchor] ??= []).add(visual.id);
      } else {
        trailing.add(visual.id);
      }
    } else {
      (byOrdinal[row] ??= []).add(visual.id);
    }
  }
  return VisualPlacement(byOrdinal, trailing, earlier);
}

/// The first `visualize` call whose answer names [id].
int? _callOf(List<ChatMessage> messages, String id) {
  final named = RegExp('"id"\\s*:\\s*"${RegExp.escape(id)}"');
  for (var i = 0; i < messages.length; i++) {
    final tool = messages[i].tool;
    if (tool == null || !tool.name.endsWith('visualize')) continue;
    final output = tool.output;
    if (output != null && named.hasMatch(output)) return i;
  }
  return null;
}

/// The last message written at or before [visual] was first drawn.
int? _timeOf(List<ChatMessage> messages, SessionVisual visual) {
  int? last;
  for (var i = 0; i < messages.length; i++) {
    final at = messages[i].at;
    if (at == null) continue;
    if (at.isAfter(visual.createdAt)) break;
    last = i;
  }
  return last;
}
