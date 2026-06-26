/// Canonical `type` strings for normalized session events.
///
/// Lifecycle events (`session.*`) are emitted by the session engine; content
/// events (`message.*`, `agent.*`, `tool.*`) originate from an `AgentAdapter`.
/// Keeping them centralized lets the UI and the future mobile app rely on a
/// stable vocabulary regardless of which agent produced them.
class SessionEventTypes {
  const SessionEventTypes._();

  static const sessionStarted = 'session.started';
  static const sessionCompleted = 'session.completed';
  static const sessionFailed = 'session.failed';
  static const sessionCancelled = 'session.cancelled';

  static const userMessage = 'message.user';
  static const agentMessage = 'message.agent';
  static const agentStatus = 'agent.status';
  static const error = 'session.error';
}
