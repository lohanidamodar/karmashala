import 'package:karmashala_artifacts/karmashala_artifacts.dart';

import '../../sessions/presentation/chat_transcript.dart';

/// Which row of a conversation each artifact's card hangs under, and those
/// with no row to hang on — drawn at the foot of the conversation instead.
class ArtifactPlacement {
  const ArtifactPlacement(this.byOrdinal, this.unplaced);

  static const empty = ArtifactPlacement({}, []);

  final Map<int, List<Artifact>> byOrdinal;
  final List<Artifact> unplaced;
}

/// Places each of [artifacts] at the turn that made it: on the agent's first
/// reply written after it within that turn, else the turn's last agent reply
/// before it. One older than every message held, or in a conversation whose
/// rows carry no time, is unplaced rather than filed under the wrong turn.
ArtifactPlacement placeArtifacts(
  List<ChatMessage> messages,
  List<Artifact> artifacts,
) {
  if (artifacts.isEmpty) return ArtifactPlacement.empty;
  final firstTimed = messages.where((m) => m.at != null).firstOrNull?.at;
  final byOrdinal = <int, List<Artifact>>{};
  final unplaced = <Artifact>[];
  for (final artifact in artifacts) {
    final shown = artifact.createdAt;
    if (firstTimed == null || shown.isBefore(firstTimed)) {
      unplaced.add(artifact);
      continue;
    }
    int? after;
    int? before;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final at = m.at;
      if (at == null) continue;
      if (!at.isAfter(shown)) {
        if (m.role == 'user') before = null;
        if (m.role == 'agent') before = i;
        continue;
      }
      if (m.role == 'user') break;
      if (m.role == 'agent') {
        after = i;
        break;
      }
    }
    final ordinal = after ?? before;
    if (ordinal == null) {
      unplaced.add(artifact);
    } else {
      (byOrdinal[ordinal] ??= []).add(artifact);
    }
  }
  return ArtifactPlacement(byOrdinal, unplaced);
}
