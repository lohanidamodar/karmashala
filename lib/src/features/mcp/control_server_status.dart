import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which transport privileged `/rpc` ended up on, if any.
///
/// See `LauncherControlServer`'s threat model: privileged RPC opens sessions,
/// launches terminals and drives attached devices, so it is only ever served
/// where the owner-only boundary around it could actually be established.
enum PrivilegedRpcTransport {
  /// The control server has not been started (or has been stopped).
  notStarted,

  /// A local socket in a directory locked to this account. The normal case.
  ownerOnlySocket,

  /// Authenticated loopback HTTP. Only reachable when a caller explicitly asks
  /// for it in code (`useLocalSocket: false`); nothing in the app does.
  loopbackHttp,

  /// No privileged transport at all. Hardening failed, so nothing privileged
  /// was bound and no privileged credential was published — `/agent-hook`,
  /// which is deliberately low-privilege, is all that is served.
  unavailable,
}

/// Which step of the hardening failed, when one did.
enum ControlServerFailureStage {
  /// The owner-only directory the RPC socket lives in could not be restricted.
  socketDirectoryPermissions,

  /// The directory was restricted, but the socket itself would not bind.
  socketBind,

  /// The handshake file that publishes the privileged token could not be
  /// restricted, so the token was not written into it.
  handshakePermissions,
}

/// What the local control server managed to bring up, as a settings screen can
/// show it.
///
/// Exists because the fail-closed path is silent by construction: withholding
/// privileged RPC removes agent tooling the user asked for, and "my agent
/// cannot see my sessions" with nothing on screen to explain it is a worse
/// outcome than the failure itself.
@immutable
class ControlServerStatus {
  const ControlServerStatus._({
    required this.transport,
    required this.hookEndpointAvailable,
    this.failureStage,
    this.failureDetail,
  });

  /// Before `start()`, and after `stop()`.
  static const ControlServerStatus notStarted = ControlServerStatus._(
    transport: PrivilegedRpcTransport.notStarted,
    hookEndpointAvailable: false,
  );

  /// Privileged RPC is up on [transport].
  const ControlServerStatus.running(PrivilegedRpcTransport transport)
    : this._(transport: transport, hookEndpointAvailable: true);

  /// Hardening failed at [stage]: only `/agent-hook` is served, and no
  /// privileged credential or transport was published.
  const ControlServerStatus.failedClosed({
    required ControlServerFailureStage stage,
    required String detail,
    bool hookEndpointAvailable = true,
  }) : this._(
         transport: PrivilegedRpcTransport.unavailable,
         hookEndpointAvailable: hookEndpointAvailable,
         failureStage: stage,
         failureDetail: detail,
       );

  final PrivilegedRpcTransport transport;

  /// Whether agents' installed hooks can still report status. This survives
  /// every hardening failure — that is the point of failing *closed* rather
  /// than not starting at all.
  final bool hookEndpointAvailable;

  final ControlServerFailureStage? failureStage;

  /// The underlying reason, as the failing tool reported it.
  final String? failureDetail;

  bool get privilegedRpcAvailable =>
      transport == PrivilegedRpcTransport.ownerOnlySocket ||
      transport == PrivilegedRpcTransport.loopbackHttp;

  bool get failedClosed => transport == PrivilegedRpcTransport.unavailable;

  /// A single line for the settings screen.
  String get message => switch (transport) {
    PrivilegedRpcTransport.notStarted => 'Not running.',
    PrivilegedRpcTransport.ownerOnlySocket =>
      'Agent tools are available over the owner-only socket.',
    PrivilegedRpcTransport.loopbackHttp =>
      'Agent tools are available over authenticated loopback.',
    PrivilegedRpcTransport.unavailable =>
      'Agent tools are off — $_stageMessage. Agents can still report status.',
  };

  String get _stageMessage => switch (failureStage) {
    ControlServerFailureStage.socketDirectoryPermissions =>
      'the socket folder could not be locked to your account',
    ControlServerFailureStage.socketBind =>
      'the owner-only socket could not be created',
    ControlServerFailureStage.handshakePermissions =>
      'the handshake file could not be locked to your account',
    null => 'the owner-only channel could not be established',
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ControlServerStatus &&
          other.transport == transport &&
          other.hookEndpointAvailable == hookEndpointAvailable &&
          other.failureStage == failureStage &&
          other.failureDetail == failureDetail;

  @override
  int get hashCode => Object.hash(
    transport,
    hookEndpointAvailable,
    failureStage,
    failureDetail,
  );

  @override
  String toString() =>
      'ControlServerStatus(${transport.name}, hook=$hookEndpointAvailable'
      '${failureStage == null ? '' : ', ${failureStage!.name}: $failureDetail'})';
}

/// Ambient state, written by `LauncherControlServer` as it starts and stops.
class ControlServerStatusController extends Notifier<ControlServerStatus> {
  @override
  ControlServerStatus build() => ControlServerStatus.notStarted;

  void set(ControlServerStatus next) {
    if (state != next) state = next;
  }
}

final controlServerStatusProvider =
    NotifierProvider<ControlServerStatusController, ControlServerStatus>(
      ControlServerStatusController.new,
    );
