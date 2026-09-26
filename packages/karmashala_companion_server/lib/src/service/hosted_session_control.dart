import 'package:karmashala_remote/remote.dart';

/// What the session host does with its own sessions for a phone while no
/// desktop app is connected: start one, resume an ended one, and read or
/// change the model and permission mode one runs under — each through the
/// agent's adapter, in PTYs the host holds. The host implements it; this
/// package never sees a PTY or a launch.
///
/// Every refusal is a `RemoteApiRefusal` in words a phone can show.
abstract interface class HostedSessionControl {
  /// Starts a new session as `session.start` asks.
  Future<RemoteSessionStarted> start(RemoteSessionStartRequest request);

  /// Resumes [sessionId]'s conversation — or answers the session as it is,
  /// when the host is still running it.
  Future<RemoteSessionStarted> resume(String sessionId);

  /// The models and permission modes [sessionId] can be put on.
  Future<RemoteSessionOptions> options(String sessionId);

  /// Records a model and/or permission mode for [sessionId], and moves the
  /// running session where its agent allows it.
  Future<RemoteConfigureOutcome> configure(
    String sessionId, {
    ({String? id})? model,
    ({String? id})? permission,
  });
}
