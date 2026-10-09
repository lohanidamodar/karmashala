import 'package:karmashala_browser/tools.dart' show browserToolSchemas;
import 'package:karmashala_mcp/instructions.dart';

import '../../artifacts/artifact_tool_set.dart' show artifactToolSchemas;
import '../../artifacts/visualize_tool_set.dart' show visualizeToolSchemas;
import '../../automations/checks_tool_set.dart';
import '../../checkpoints/checkpoint_screenshot_tool_set.dart'
    show checkpointScreenshotToolSchemas;
import '../../checkpoints/checkpoint_tool_set.dart';
import 'decision_tool_set.dart';
import 'project_tool_set.dart';
import 'verification_tool_schemas.dart';
import 'github_run_tool_set.dart';
import 'session_checkout_tool_set.dart';
import 'workspace_tool_set.dart';
import 'worktree_tool_set.dart';
import 'fanout_tool_set.dart';
import 'inventory_tool_set.dart';
import 'launch_tool_set.dart';
import 'notes_todos_tool_set.dart';
import 'review_thread_tool_set.dart';
import 'snippet_tool_set.dart';
import 'session_archive_tool_set.dart' show sessionArchiveToolSchemas;
import 'session_tool_schemas.dart';
import '../../pipelines/pipeline_tool_set.dart' show pipelineToolSchemas;
import 'usage_tool_set.dart';
import 'webhook_tool_set.dart' show webhookToolSchemas;
import 'secret_tool_set.dart' show secretToolSchemas;
import 'store_tool_set.dart' show storeToolSchemas;
import 'inbox_tool_set.dart';
import 'build_tool_schemas.dart';
import 'device_tool_set.dart' show deviceToolSchemas;
import 'flutter_tool_schemas.dart';
import 'continuation_tool_set.dart' show sessionHandoffToolSchemas;
import 'recording_tool_schemas.dart';
import 'terminal_tool_schemas.dart';
import 'dev_server_tool_set.dart';
import 'window_tool_sets.dart'
    show
        openSessionToolSchemas,
        sessionDraftToolSchemas,
        snippetControlToolSchemas,
        workspaceControlToolSchemas;

/// Every tool the server runs itself, in the order `tools/list` serves them —
/// every agent tool since slice 5b, before the few the app still answers (the
/// attention inbox, until slice 5c). `serve` registers one family per group
/// below, in this order; the last six groups are the app's old list, in its
/// old order, so the served catalogue only lost `open_sessions_in_tmux`.
const List<Map<String, Object?>> serverToolSchemas = [
  ...instructionsToolSchemas,
  ...inventoryToolSchemas,
  ...notesTodosToolSchemas,
  ...decisionToolSchemas,
  ...reviewThreadToolSchemas,
  ...snippetToolSchemas,
  ...fanOutToolSchemas,
  ...workspaceToolSchemas,
  ...gitHubRunToolSchemas,
  ...secretToolSchemas,
  ...projectToolSchemas,
  ...worktreeToolSchemas,
  ...sessionCheckoutToolSchemas,
  ...verificationToolSchemas,
  ...checkpointToolSchemas,
  ...checkpointScreenshotToolSchemas,
  ...artifactToolSchemas,
  ...visualizeToolSchemas,
  ...checksToolSchemas,
  ...webhookToolSchemas,
  ...sessionControlToolSchemas,
  ...sessionArchiveToolSchemas,
  ...launchToolSchemas,
  ...pipelineToolSchemas,
  ...usageToolSchemas,
  ...storeToolSchemas,
  ...inboxToolSchemas,
  ...browserToolSchemas,
  ...flutterAppToolSchemas,
  ...flutterRunToolSchemas,
  ...projectBuildToolSchemas,
  ...deviceToolSchemas,
  ...openSessionToolSchemas,
  ...sessionHandoffToolSchemas,
  ...terminalControlToolSchemas,
  ...devServerToolSchemas,
  ...recordingControlToolSchemas,
  ...snippetControlToolSchemas,
  ...sessionDraftToolSchemas,
  ...workspaceControlToolSchemas,
];
