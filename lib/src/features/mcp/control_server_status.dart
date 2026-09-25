import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which transport privileged `/rpc` ended up on, if any: it is served only
/// where the owner-only boundary around it could actually be established.
enum PrivilegedRpcTransport {
  /// The control server has not been started (or has been stopped).
  notStarted,

  /// A local socket in a directory locked to this account. The normal case.
  ownerOnlySocket,

  /// Authenticated loopback HTTP. Only reachable when a caller explicitly asks
  /// for it in code (`useLocalSocket: false`); nothing in the app does.
  loopbackHttp,

  /// The session host serves agents' tools; this app only runs them, so they
  /// are listed, and refused by name, while it is closed.
  sessionHost,

  /// No privileged transport at all: hardening failed, so nothing privileged was
  /// bound and only the deliberately low-privilege `/agent-hook` is served.
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
/// show it: the fail-closed path is otherwise silent by construction.
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

  /// The session host serves the endpoint; this app runs no server of its own.
  static const ControlServerStatus atHost = ControlServerStatus._(
    transport: PrivilegedRpcTransport.sessionHost,
    hookEndpointAvailable: true,
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

  /// Whether agents' installed hooks can still report status: this survives every
  /// hardening failure, which is the point of failing *closed*.
  final bool hookEndpointAvailable;

  final ControlServerFailureStage? failureStage;

  /// The underlying reason, as the failing tool reported it.
  final String? failureDetail;

  bool get privilegedRpcAvailable =>
      transport == PrivilegedRpcTransport.ownerOnlySocket ||
      transport == PrivilegedRpcTransport.loopbackHttp ||
      transport == PrivilegedRpcTransport.sessionHost;

  bool get failedClosed => transport == PrivilegedRpcTransport.unavailable;

  /// A single line for the settings screen.
  String get message => switch (transport) {
    PrivilegedRpcTransport.notStarted => 'Not running.',
    PrivilegedRpcTransport.ownerOnlySocket =>
      'Agent tools are available over the owner-only socket.',
    PrivilegedRpcTransport.loopbackHttp =>
      'Agent tools are available over authenticated loopback.',
    PrivilegedRpcTransport.sessionHost =>
      'Agent tools are served by the session host, and keep their '
          'connection while the app is closed.',
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

/// Ambient state, written by whichever of `LauncherControlServer` and
/// `HostAgentTools` this run started.
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
