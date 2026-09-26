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

/// Every tool the server runs itself, in the order `tools/list` serves them —
/// before the app's own (panes, the editor, browsers, devices, recordings).
/// `serve` registers one family per group below, in this order.
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
];
