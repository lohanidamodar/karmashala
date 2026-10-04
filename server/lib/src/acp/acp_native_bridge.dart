import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec, AcpNativeBridge;

import 'acp_transport.dart';
import 'claude/claude_stream_json_bridge.dart';

/// Speaks an agent's own protocol to [raw], the agent's process, and ACP to
/// Karmashala: what an ACP adapter does, in-process, over the agent's own
/// binary and login.
typedef AcpBridge = AcpTransport Function(AcpTransport raw);

/// The bridges this build carries, one per [AcpNativeBridge] it can speak.
/// Each is added here beside its implementation.
const Map<AcpNativeBridge, AcpBridge> kAcpNativeBridges = {
  AcpNativeBridge.claudeStreamJson: claudeStreamJsonBridge,
};

/// The transport ACP is spoken over for an agent launched under [spec]:
/// [raw] itself for an agent that speaks ACP, else [raw] wrapped by the
/// bridge for its protocol. Every place an ACP agent's process is opened
/// goes through here — the session runtime, the login, the version read —
/// so none of them can see the native protocol.
AcpTransport bridgedAcpTransport(
  AcpLaunchSpec spec,
  AcpTransport raw, {
  Map<AcpNativeBridge, AcpBridge> bridges = kAcpNativeBridges,
}) {
  final native = spec.nativeBridge;
  if (native == null) return raw;
  final bridge = bridges[native];
  if (bridge == null) {
    throw StateError(
      'This build cannot speak ${native.name}, the protocol this agent is '
      'started in.',
    );
  }
  return bridge(raw);
}
