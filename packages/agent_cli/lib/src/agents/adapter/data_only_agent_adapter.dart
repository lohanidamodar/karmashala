import '../domain/agent_descriptor.dart';
import 'agent_adapter.dart';

/// **An agent that exists only as data**: a descriptor and no code.
///
/// It is discovered, persisted, listed, launched from its descriptor, streamed
/// as plain text and asked one question the way its descriptor says — and it
/// declares no other capability, so every caller degrades for it rather than
/// guessing. This is where a new agent starts, before anything about it has
/// been established by running the CLI.
class DataOnlyAgentAdapter extends AgentAdapter {
  const DataOnlyAgentAdapter(this.descriptor);

  @override
  final AgentDescriptor descriptor;
}
