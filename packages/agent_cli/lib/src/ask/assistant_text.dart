import '../agents/adapter/agent_chat_protocol.dart';
import '../sessions/session_event_types.dart';

/// The assistant text in [events], or null when they carry none.
///
/// A one-shot answer is filtered out of the same event vocabulary a chat
/// protocol produces, rather than read a second way.
String? assistantTextIn(List<AgentEvent> events) {
  final buffer = StringBuffer();
  for (final event in events) {
    if (event.type != SessionEventTypes.agentMessage) continue;
    buffer.write(event.data['text'] ?? '');
  }
  final out = buffer.toString();
  return out.isEmpty ? null : out;
}
