import '../protocol/messages.dart';

/// What the host server hands automation frames to. The daemon's automations
/// implement it; a test hands in a fake.
abstract interface class AutomationHandler {
  /// News from [owner]: it is the app ([AutomationNoticeKind.ready]) — frames
  /// to it go through [send] — or it wrote automation rows.
  void notice(
    Object owner,
    AutomationNoticeMessage notice,
    void Function(HostMessage) send,
  );

  /// [owner]'s answer to a call forwarded to it.
  void answer(Object owner, AutomationResultMessage result);

  /// Runs a session's project checks here, or says why not.
  Future<ChecksRanMessage> runChecks(ChecksRunMessage request);

  /// [owner] hung up.
  void detach(Object owner);
}
