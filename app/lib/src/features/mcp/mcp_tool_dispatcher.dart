import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../core/util/clock_provider.dart';
import '../automations/application/project_check_tools.dart';
import '../browser/application/browser_consent_providers.dart';
import '../browser/application/browser_providers.dart';
import 'package:karmashala_browser/tools.dart';
import '../flutter_apps/application/flutter_app_tools.dart';
import '../app_projects/application/project_build_tools.dart';
import '../flutter_apps/application/flutter_run_tools.dart';
import '../verification/application/verification_providers.dart';
import '../verification/application/verification_tool_schemas.dart';
import '../verification/application/verification_tools.dart';
import 'attention_tools.dart';
import 'checkpoint_tools.dart';
import 'decision_tools.dart';
import 'review_thread_tools.dart';
import 'device_tools.dart';
import 'fanout_tools.dart';
import 'package:karmashala_mcp/instructions.dart';
import 'inventory_tools.dart';
import 'project_tools.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'session_launch_tools.dart';
import 'session_tools.dart';
import 'snippet_tools.dart';
import 'recording_tools.dart';
import 'terminal_tools.dart';
import 'tmux_tools.dart';
import 'todo_tools.dart';
import 'workspace_tools.dart';
import 'worktree_tools.dart';
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
      case final String name when InventoryTools.handles(name):
        return InventoryTools(_container).call(name, args);
      case final String name when ProjectControlTools.handles(name):
        return ProjectControlTools(_container).call(name, args);
      // The caller's identity matters: a session started here is recorded as
      // its child, which is what the spawn-depth cap counts.
      case final String name when SessionLaunchTools.handles(name):
        return SessionLaunchTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when FanOutTools.handles(name):
        return FanOutTools(_container).call(name, args);
      case final String name when TmuxControlTools.handles(name):
        return TmuxControlTools(_container).call(name, args);
      case final String name when CheckpointControlTools.handles(name):
        return CheckpointControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
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
      case final String name when TodoControlTools.handles(name):
        return TodoControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when DecisionControlTools.handles(name):
        return DecisionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when ReviewThreadTools.handles(name):
        return ReviewThreadTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when WorkspaceControlTools.handles(name):
        return WorkspaceControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when WorktreeControlTools.handles(name):
        return WorktreeControlTools(_container).call(name, args);
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
      case final String name when InstructionsTools.handles(name):
        return const InstructionsTools().call(name, args);
      // Consent is resolved here, not in features/browser: which project a call
      // is for is a sessions question, and nothing about it is cached.
      case final String name when BrowserTools.handles(name):
        return BrowserTools(
          _container.read(browserServiceProvider),
          consent: browserConsentFor(
            _container,
            callerSessionId: callerSessionId,
          ),
        ).call(name, args);
      case final String name when FlutterAppTools.handles(name):
        return FlutterAppTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when FlutterRunTools.handles(name):
        return FlutterRunTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when ProjectBuildTools.handles(name):
        return ProjectBuildTools(_container).call(name, args);
      case final String name when ProjectCheckTools.handles(name):
        return ProjectCheckTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when VerificationTools.handles(name):
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

  /// MCP tool definitions (name/description/inputSchema), as the app defines
  /// them; [catalogue] is what `tools/list` serves.
  static const List<Map<String, dynamic>> toolSchemas = [
    ...checkpointControlToolSchemas,
    ...inventoryToolSchemas,
    ...projectControlToolSchemas,
    ...projectCheckToolSchemas,
    ...sessionLaunchToolSchemas,
    ...fanOutToolSchemas,
    ...sessionHandoffToolSchemas,
    ...tmuxToolSchemas,
    ...instructionsToolSchemas,
    ...sessionControlToolSchemas,
    ...terminalControlToolSchemas,
    ...recordingControlToolSchemas,
    ...snippetControlToolSchemas,
    ...workspaceControlToolSchemas,
    ...worktreeControlToolSchemas,
    ...deviceControlToolSchemas,
    ...attentionControlToolSchemas,
    ...todoControlToolSchemas,
    ...decisionControlToolSchemas,
    ...reviewThreadToolSchemas,
    ...browserToolSchemas,
    ...flutterAppToolSchemas,
    ...flutterRunToolSchemas,
    ...projectBuildToolSchemas,
    ...verificationToolSchemas,
  ];
}

/// The one dispatcher per app, so a launch retried over a different transport
/// still collapses onto the first.
final mcpToolDispatcherProvider = Provider<McpToolDispatcher>(
  (ref) => McpToolDispatcher(ref.container),
);
