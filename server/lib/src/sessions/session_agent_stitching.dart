import 'package:agent_cli/read.dart' show TranscriptMessage, kAgentSwitchRole;
import 'package:karmashala_session/session.dart' show SessionAgentSpan;

/// One span's rows as its source holds them: for a span the server keeps
/// ([fromMessages]) every `session_messages` row of the session, by ordinal;
/// otherwise the whole of that agent's conversation file.
typedef SpanSource = ({SessionAgentSpan span, bool fromMessages, List<TranscriptMessage> rows});

/// **A switched session's transcript, one span after another**: each span's
/// rows cut from its own source, tagged with its agent, and every span after
/// the first opened by a [kAgentSwitchRole] row carrying what that agent was
/// handed — the packet itself is not repeated as a user turn.
List<TranscriptMessage> stitchAgentSpans(List<SpanSource> sources) {
  final out = <TranscriptMessage>[];
  for (var i = 0; i < sources.length; i++) {
    final (:span, :fromMessages, :rows) = sources[i];
    final later = sources.sublist(i + 1);
    final List<TranscriptMessage> own;
    if (fromMessages) {
      final from = (span.firstMessageOrdinal ?? 0).clamp(0, rows.length);
      final next = later
          .map((s) => s.span.firstMessageOrdinal)
          .whereType<int>()
          .firstOrNull;
      final end = (next ?? rows.length).clamp(from, rows.length);
      own = rows.sublist(from, end);
    } else {
      own = _within(
        rows,
        // The first span owns whatever came before the row did, such as an
        // imported conversation's history.
        from: span.seq == 0 ? null : span.startedAt,
        before: later.isEmpty ? null : later.first.span.startedAt,
      );
    }
    final agent = span.agentInstallationId;
    if (span.seq > 0) {
      out.add(
        TranscriptMessage(
          role: kAgentSwitchRole,
          text: span.carriedPacket ?? '',
          at: span.startedAt,
          agentInstallationId: agent,
        ),
      );
    }
    var packetSkipped = span.seq == 0;
    for (final row in own) {
      if (!packetSkipped && row.role == 'user') {
        packetSkipped = true;
        if (isCarriedPacket(row.text, span.carriedPacket)) continue;
      }
      out.add(row.withAgent(agent));
    }
  }
  return out;
}

/// What an agent switched in is asked to do when the person said nothing.
const String kSwitchInstruction =
    'You are taking over this session in place. Pick the work up where the '
    'conversation stands: if the last request is finished, say so in a line '
    'and wait for the next message.';

/// Whether [text], a span's first user turn, is the packet it was handed —
/// typed whole, or as the one line pointing at the file it was written to.
bool isCarriedPacket(String text, String? packet) {
  final said = text.trim();
  if (packet != null && packet.trim().isNotEmpty && said == packet.trim()) {
    return true;
  }
  if (said == kSwitchInstruction) return true;
  return said.startsWith('# Handed off from ') ||
      said.startsWith('Your brief for this session is in the file ') ||
      // As sessions before the handoff store were handed theirs: the packet
      // as a brief file, or typed through a prompt file.
      said.startsWith('Your handoff brief for this session is the file ') ||
      (said.startsWith('My opening message to you is in the file ') &&
          said.contains('handoff'));
}

/// [rows] from [from] (inclusive) to [before] (exclusive); a row with no time
/// of its own goes with the one before it.
List<TranscriptMessage> _within(
  List<TranscriptMessage> rows, {
  DateTime? from,
  DateTime? before,
}) {
  final kept = <TranscriptMessage>[];
  DateTime? last;
  for (final row in rows) {
    final at = row.at ?? last;
    last = at;
    if (from != null && (at == null || at.isBefore(from))) continue;
    if (before != null && at != null && !at.isBefore(before)) continue;
    kept.add(row);
  }
  return kept;
}

/// What [SessionTranscripts] needs to read a switched session span by span.
class AgentSpanReaders {
  const AgentSpanReaders({
    required this.spansOf,
    required this.agentIdOf,
    required this.speaksAcp,
    required this.locate,
  });

  /// [String]'s spans with the active one's conversation filled in from the
  /// row; empty for a session that never switched.
  final List<SessionAgentSpan> Function(String sessionId) spansOf;
  final String? Function(String installationId) agentIdOf;

  /// Whether an installation's turns are kept in `session_messages`.
  final bool Function(String installationId) speaksAcp;

  /// Where an agent keeps a conversation's record, as `lookUp` answers it.
  final Future<String?> Function(String agentId, String conversationId)
  locate;
}
