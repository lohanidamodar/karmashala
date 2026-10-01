import 'package:karmashala_browser/tools.dart' show browserToolSchemas;
import 'package:karmashala_mcp/instructions.dart';

import '../../automations/checks_tool_set.dart';
import '../../checkpoints/checkpoint_tool_set.dart';
import 'decision_tool_set.dart';
import 'project_tool_set.dart';
import 'verification_tool_schemas.dart';
import 'workspace_tool_set.dart';
import 'worktree_tool_set.dart';
import 'fanout_tool_set.dart';
import 'inventory_tool_set.dart';
import 'launch_tool_set.dart';
import 'notes_todos_tool_set.dart';
import 'review_thread_tool_set.dart';
import 'snippet_tool_set.dart';
import 'session_tool_schemas.dart';
import 'usage_tool_set.dart';
import 'inbox_tool_set.dart';
import 'build_tool_schemas.dart';
import 'device_tool_set.dart' show deviceToolSchemas;
import 'flutter_tool_schemas.dart';
import 'continuation_tool_set.dart' show sessionHandoffToolSchemas;
import 'recording_tool_schemas.dart';
import 'terminal_tool_schemas.dart';
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
  ...projectToolSchemas,
  ...worktreeToolSchemas,
  ...verificationToolSchemas,
  ...checkpointToolSchemas,
  ...checksToolSchemas,
  ...sessionControlToolSchemas,
  ...launchToolSchemas,
  ...usageToolSchemas,
  ...inboxToolSchemas,
  ...browserToolSchemas,
  ...flutterAppToolSchemas,
  ...flutterRunToolSchemas,
  ...projectBuildToolSchemas,
  ...deviceToolSchemas,
  ...openSessionToolSchemas,
  ...sessionHandoffToolSchemas,
  ...terminalControlToolSchemas,
  ...recordingControlToolSchemas,
  ...snippetControlToolSchemas,
  ...sessionDraftToolSchemas,
  ...workspaceControlToolSchemas,
];
