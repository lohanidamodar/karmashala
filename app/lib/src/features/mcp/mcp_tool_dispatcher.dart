import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../core/util/clock_provider.dart';
import '../automations/application/project_check_tools.dart';
import '../verification/application/verification_providers.dart';
import 'package:karmashala_verification/tools.dart';
import 'attention_tools.dart';
import 'decision_tools.dart';
import 'device_tools.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:karmashala_host/mcp_tools.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'session_launch_tools.dart';
import 'session_tools.dart';
import 'snippet_tools.dart';
import 'recording_tools.dart';
import 'terminal_tools.dart';
import 'tmux_tools.dart';
import 'workspace_tools.dart';
import '../sessions/application/host_lifecycle/host_lifecycle_subscriber.dart'
    show HostMcpTools;

/// Runs one agent tool call in this app, as the session the transport
/// authenticated — whether that transport is this app's own server or the
/// session host forwarding a call it took.
class McpToolDispatcher implements HostMcpTools {
  McpToolDispatcher(this._container, {AppLogger? logger})
    : _logger = logger ?? AppLogger.named('mcp-control');

  final ProviderContainer _container;
  final AppLogger _logger;

  /// One agent per request, however often it arrives: a worktree under `/mnt/c`
  /// outlives the 60s Claude Code waits, and its retry started a second agent.
  late final LaunchDedupe _launches = LaunchDedupe(
    clock: _container.read(clockProvider),
    onCollapsed: (tool) => _logger.warning(
      'A repeat $tool was collapsed onto the identical launch already made; '
      'nothing new was started. The caller most likely timed out and retried.',
    ),
  );

  /// What `tools/list` serves, annotated with what each tool does to the world.
  static List<Map<String, dynamic>> servedCatalogue() =>
      annotatedToolSchemas(toolSchemas);

  /// What this app's own control server serves where no Karmashala server
  /// runs (and so nothing else serves agents): its own tools, and the
  /// server's tools it still answers for its own panes. Everything else needs
  /// the server.
  static List<Map<String, dynamic>> standaloneCatalogue() =>
      annotatedToolSchemas([
        ...toolSchemas,
        for (final schema in serverToolSchemas)
          if (answeredForOwnPanes.contains(schema['name'])) schema,
      ]);

  /// The server's tools a forwarded call still lands here for: a session in
  /// one of this app's panes, a device verification run, a check
  /// in a checkout only this app's panes reach. An SSH checkout is the
  /// server's own since slice 3a.
  static const Set<String> answeredForOwnPanes = {
    'session_send',
    'session_answer',
    'session_wait',
    'session_transcript',
    'session_rename',
    'session_end',
    'open_new_session',
    'verification_start',
    'verification_note',
    'verification_finish',
    'verification_list',
    'verification_get',
    'checks_run',
  };

  @override
  List<Map<String, Object?>> catalogue() => servedCatalogue();

  @override
  Future<Object?> call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => dispatch(tool, arguments, callerSessionId);

  /// One RPC, guarded against being made twice. Only the tools that *start*
  /// something go through the ledger; a read must not be collapsed.
  Future<Object?> dispatch(
    String? tool,
    Map<String, dynamic> args, [
    String? callerSessionId,
  ]) {
    if (tool != null && startsAnAgent(tool, args)) {
      return _launches.run(
        tool: tool,
        arguments: args,
        callerSessionId: callerSessionId,
        start: () => _invoke(tool, args, callerSessionId),
      );
    }
    return _invoke(tool, args, callerSessionId);
  }

  Future<Object?> _invoke(
    String? tool,
    Map<String, dynamic> args, [
    String? callerSessionId,
  ]) async {
    switch (tool) {
      case '__list_tools__':
        return toolSchemas;
      // The caller's identity matters: a session started here is recorded as
      // its child, which is what the spawn-depth cap counts.
      case final String name when SessionLaunchTools.handles(name):
        return SessionLaunchTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when TmuxControlTools.handles(name):
        return TmuxControlTools(_container).call(name, args);
      case final String name when SessionControlTools.handles(name):
        return SessionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when AttentionControlTools.handles(name):
        return AttentionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when WorkspaceControlTools.handles(name):
        return WorkspaceControlTools(_container).call(name, args);
      case final String name when DeviceControlTools.handles(name):
        return DeviceControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when TerminalControlTools.handles(name):
        return TerminalControlTools(_container).call(name, args);
      case final String name when RecordingControlTools.handles(name):
        return RecordingControlTools(_container).call(name, args);
      case final String name when SnippetControlTools.handles(name):
        return SnippetControlTools(_container).call(name, args);
      case final String name when ProjectCheckTools.handles(name):
        return ProjectCheckTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when name.startsWith('verification_'):
        await resolveVerificationRoot();
        final verification = _container.read(verificationServiceProvider);
        // Noted *before* the call, because finishing clears the active run: the
        // seam where verification writes to the decision record.
        final finishing = name == 'verification_finish'
            ? verification.activeRun?.id
            : null;
        // The caller is the producer of every verdict recorded here (G3).
        final answer = await VerificationTools(
          verification,
          callerSessionId: callerSessionId,
        ).call(name, args);
        if (finishing != null) {
          recordFinishedVerdict(_container, await verification.get(finishing));
        }
        return answer;
      default:
        throw ArgumentError('Unknown tool: $tool');
    }
  }

  /// The tools only this app can run — its panes, the editor,
  /// devices, recordings, the inbox, and continuing a session into a visible
  /// tab. The server runs every other tool itself and serves these beside its
  /// own; a call it forwards for a tool it also serves (a session in one of
  /// this app's panes) still lands in [dispatch].
  static const List<Map<String, dynamic>> toolSchemas = [
    ...sessionLaunchToolSchemas,
    ...sessionHandoffToolSchemas,
    ...tmuxToolSchemas,
    ...terminalControlToolSchemas,
    ...recordingControlToolSchemas,
    ...snippetControlToolSchemas,
    ...workspaceControlToolSchemas,
    ...deviceControlToolSchemas,
    ...attentionControlToolSchemas,
  ];
}

/// The one dispatcher per app, so a launch retried over a different transport
/// still collapses onto the first.
final mcpToolDispatcherProvider = Provider<McpToolDispatcher>(
  (ref) => McpToolDispatcher(ref.container),
);
