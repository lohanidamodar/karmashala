import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../agents/application/host_hook_endpoint.dart';
import '../checkpoints/application/session_checkpoint_recorder.dart';
import '../terminal/application/local_host_providers.dart';
import 'control_server_status.dart';
import 'host_session_mcp.dart';
import 'mcp_session_token_reaper.dart';
import 'session_mcp.dart';

/// Whether this machine's session host serves agents' MCP: whenever local
/// panes are host-backed. This app then runs no control server of its own.
final agentToolsAtHostProvider = Provider<bool>(
  (ref) => ref.watch(agentHooksAtHostProvider),
);

/// This app's half of agent tools when the session host serves them: launches
/// are pointed at the host's endpoint with host-issued tokens, and the tools
/// themselves run when the host forwards a call over the lifecycle link.
class HostAgentTools {
  HostAgentTools(
    this._container, {
    AppLogger? logger,
    HandshakePermissions? permissions,
  }) : _logger = logger ?? AppLogger.named('mcp-control'),
       _permissions = permissions ?? const SystemHandshakePermissions();

  final ProviderContainer _container;
  final AppLogger _logger;
  final HandshakePermissions _permissions;
  McpSessionTokenReaper? _reaper;

  /// Publishes [HostSessionMcp]. False, with nothing published, when there is
  /// no local host to point at.
  Future<bool> start({String? sessionConfigDirectory}) async {
    final access = _container.read(localHostSessionAccessProvider);
    final dataDirectory = await access?.dataDirectory?.call();
    if (access == null || dataDirectory == null) return false;
    // Kept, not emptied: the tokens in them outlive this app, and a running
    // agent may read its config again.
    final configDirectory =
        sessionConfigDirectory ?? p.join(dataDirectory, 'mcp');
    final configs = await SessionMcpConfigs.prepare(
      Directory(configDirectory),
      (dir) => _permissions.restrictDirectory(dir, logger: _logger),
      keep: true,
    );
    if (configs == null) {
      _logger.warning(
        'MCP session configs are off: $configDirectory could not be locked to '
        'this user. Agents that need a config file will launch without one.',
      );
    }
    _container
        .read(sessionMcpProvider.notifier)
        .adopt(
          HostSessionMcp(
            handshakePath: p.join(dataDirectory, McpBridgeHandshake.fileName),
            credentialsPath: access.paths.mcpCredentialsPath,
            configs: configs,
          ),
        );
    _container
        .read(controlServerStatusProvider.notifier)
        .set(ControlServerStatus.atHost);
    try {
      _container.read(sessionCheckpointRecorderProvider.notifier).start();
    } on Object catch (error, stack) {
      _logger.warning('Checkpoint recorder failed to start.', error, stack);
    }
    _reaper = McpSessionTokenReaper(_container, null, logger: _logger)..start();
    _logger.info('Agent tools are served by the session host.');
    return true;
  }

  /// Withdraws the wiring. The configs stay: agents outlive this app.
  Future<void> stop() async {
    _reaper?.stop();
    _reaper = null;
    try {
      _container.read(sessionMcpProvider.notifier).adopt(null);
      _container
          .read(controlServerStatusProvider.notifier)
          .set(ControlServerStatus.notStarted);
    } on Object catch (error) {
      // A disposed container on the way out.
      _logger.warning('Could not withdraw the host MCP wiring: $error');
    }
  }
}
