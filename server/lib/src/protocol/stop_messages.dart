part of 'messages.dart';

// The version-independent pair: `karmashala_host stop` must reach a host of
// any protocol, so these are answered before (and without) hello and their
// codes and payloads never change. See docs/daemon-architecture.md, "Frames
// that never change".

/// client → host, as the first and only frame: "who are you, and is anything
/// running?" Answered with [StopCheckAnswerMessage], then the host hangs up.
class StopCheckMessage extends HostMessage {
  const StopCheckMessage(this.requestId);
  final int requestId;

  @override
  Frame toFrame() =>
      Frame(MessageType.stopCheck, 0, (WireWriter()..u32(requestId)).take());

  static StopCheckMessage decode(Frame frame) =>
      StopCheckMessage(WireReader(frame.payload).u32());
}

/// host → client: its pid, the protocol it speaks for everything else, and
/// how many sessions it holds that have not ended.
class StopCheckAnswerMessage extends HostMessage {
  const StopCheckAnswerMessage({
    required this.requestId,
    required this.protocolVersion,
    required this.pid,
    required this.runningSessions,
  });

  final int requestId;
  final int protocolVersion;
  final int pid;
  final int runningSessions;

  @override
  Frame toFrame() => Frame(
    MessageType.stopCheckAnswer,
    0,
    (WireWriter()
          ..u32(requestId)
          ..u32(protocolVersion)
          ..u32(pid)
          ..u32(runningSessions))
        .take(),
  );

  static StopCheckAnswerMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return StopCheckAnswerMessage(
      requestId: r.u32(),
      protocolVersion: r.u32(),
      pid: r.u32(),
      runningSessions: r.u32(),
    );
  }
}
