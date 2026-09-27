import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_terminal_runtime/host_link.dart';
import '../../../core/probe/probe_mode.dart';
import 'host_session_providers.dart';

/// What one machine's session host is holding, and the two things a person can
/// do about it from here. The host outlives this app by design, so a session it
/// holds may have been opened by a Karmashala that is long gone.
class HostSessionsService {
  const HostSessionsService(this._access, [this._refusal]);

  final HostSessionAccess? Function(SshHost host) _access;

  /// Why nothing here is asked at all — a probe, which must not see the
  /// owner's sessions on a machine they share. Null when it may ask.
  final String? _refusal;

  /// The sessions on [host]. Throws [HostSessionsUnavailable] with a sentence
  /// worth showing when the host cannot be reached or refuses.
  Future<List<SessionSummary>> list(SshHost host) =>
      _withLink(host, (link) => link.listSessions());

  /// Ends one session for good. The pane that opened it, if any, sees its
  /// child exit exactly as it would have anyway.
  Future<void> end(SshHost host, String sessionId) =>
      _withLink(host, (link) => link.closeSession(sessionId));

  Future<T> _withLink<T>(
    SshHost host,
    Future<T> Function(HostPaneLink link) use,
  ) async {
    if (_refusal case final reason?) throw HostSessionsUnavailable(reason);
    final access = _access(host);
    if (access == null) {
      throw const HostSessionsUnavailable('This host is not reachable.');
    }
    final HostDeployment deployment;
    try {
      deployment = await access.deployment();
    } on Object catch (e) {
      throw HostSessionsUnavailable(
        'Could not ask ${host.address}: ${describeSshFailure(e)}',
      );
    }
    final remotePath = deployment.remotePath;
    if (!deployment.isReady || remotePath == null) {
      throw HostSessionsUnavailable(
        'No session host on ${host.address}: ${deployment.reason}',
        deployment: deployment,
      );
    }
    HostPaneLink? link;
    try {
      link = await HostPaneLink.open(
        await access.exec('$remotePath attach'),
        // Named so the host's own write-holder line says who is looking.
        clientId: 'karmashala-sessions',
      );
      return await use(link);
    } on HostLinkException catch (e) {
      throw HostSessionsUnavailable(e.message);
    } finally {
      await link?.close();
    }
  }
}

class HostSessionsUnavailable implements Exception {
  const HostSessionsUnavailable(this.message, {this.deployment});
  final String message;

  /// The deploy that did not end ready, when that is why — so the dialog can
  /// offer its remedy and an Install button rather than only the sentence.
  final HostDeployment? deployment;
  @override
  String toString() => message;
}

final hostSessionsServiceProvider = Provider<HostSessionsService>(
  (ref) => HostSessionsService(
    ref.read(hostSessionAccessLookupProvider),
    ref.read(probeModeProvider).enabled
        ? 'A probe does not use the session host on SSH machines: the '
              "owner's sessions are there, and it could end them. Its panes "
              'use tmux instead.'
        : null,
  ),
);

/// The pane a host session was opened by, when it was opened by one. A shell
/// session is named `karmashala_<hostId>_<paneId>`, so reattaching means
/// opening a pane under that id again; an agent's session carries the *agent's*
/// id instead and belongs to a Karmashala session, not to a bare pane.
String? paneIdOfHostSession(String sessionId, String hostId) {
  final prefix = 'karmashala_${hostId}_';
  if (!sessionId.startsWith(prefix)) return null;
  final paneId = sessionId.substring(prefix.length);
  return paneId.isEmpty ? null : paneId;
}
