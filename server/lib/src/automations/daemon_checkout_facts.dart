import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/unattended.dart';
import 'package:karmashala_git/repositories.dart';

import 'daemon_agents.dart';

/// What the session host knows about a checkout, from the shared store. The
/// host starts agents and runs commands only in this machine's own
/// environment; WSL and SSH checkouts are the app's.
class DaemonCheckoutFacts implements CheckoutFacts {
  DaemonCheckoutFacts(
    this.rows, {
    this.agents = const DaemonAgents(),
    bool? windows,
    this.remote,
  }) : _windows = windows ?? Platform.isWindows;

  final CheckoutRows rows;
  final DaemonAgents agents;
  final bool _windows;

  /// The server's runners for an SSH box (`ServerSsh`); null reaches none.
  final CommandRunnerFactory? remote;

  @override
  Repository? repository(String id) => rows.repository(id);

  @override
  AgentInstallation? installation(String id) => rows.installation(id);

  @override
  AgentDescriptor? descriptor(String agentId) => agents.descriptorOf(agentId);

  @override
  PermissionSelection resumePermission(String agentId, String? sessionMode) =>
      agents.permissionOf(agentId, sessionMode);

  /// Whether [path] is in this machine's own environment — where the host can
  /// spawn a process directly.
  bool isHostLocal(EnvironmentPath? path) {
    if (path == null) return false;
    final environment = rows.environment(path.environmentId);
    return environment != null && isHere(environment);
  }

  /// Whether a check's command can run in [path]: here, in a session this
  /// host owns, or on an SSH box over the server's own connection.
  bool runsChecksIn(EnvironmentPath? path) =>
      isHostLocal(path) || remoteRunnerFor(path) != null;

  /// The runner for [path] on an SSH box, or null when it is not on one (or
  /// no SSH is reached).
  CommandRunner? remoteRunnerFor(EnvironmentPath? path) {
    final factory = remote;
    if (factory == null || path == null) return null;
    final environment = rows.environment(path.environmentId);
    if (environment == null || environment.kind != EnvironmentKind.ssh) {
      return null;
    }
    return factory.forEnvironment(environment);
  }

  /// Whether [environment] is this machine's own.
  bool isHere(ExecutionEnvironment environment) => switch (environment.kind) {
    EnvironmentKind.localPosix => !_windows,
    EnvironmentKind.windowsNative => _windows,
    _ => false,
  };

  /// The environment [path] names, in words, for a refusal.
  String describeEnvironment(EnvironmentPath path) =>
      rows.environment(path.environmentId)?.name ?? path.environmentId;

  @override
  ({UnattendedReach reach, String reason}) reach(EnvironmentPath? path) {
    if (path == null) {
      return (
        reach: UnattendedReach.unnamed,
        reason: 'No checkout, so nothing says where its commands would run',
      );
    }
    final environment = rows.environment(path.environmentId);
    if (environment == null) {
      return (
        reach: UnattendedReach.unnamed,
        reason: 'Unknown environment: ${path.environmentId}',
      );
    }
    if (isHostLocal(path)) {
      return (reach: UnattendedReach.reachable, reason: '');
    }
    return (
      reach: UnattendedReach.unreachable,
      reason:
          'The session host runs agents only on this machine itself, and '
          '${environment.name} is not it; the Karmashala app starts those',
    );
  }
}
