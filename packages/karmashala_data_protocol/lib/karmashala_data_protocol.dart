/// The client/server data API: typed requests per domain (notes, todos,
/// preferences, the workspace, sessions, environments and agents), the change batches a server pushes, typed refusals, and the
/// JSON envelope that carries them over any transport.
library;

export 'src/agent_work_values.dart';
export 'src/automation_values.dart';
export 'src/data_change.dart';
export 'src/data_endpoint.dart';
export 'src/data_envelope.dart';
export 'src/data_request.dart';
export 'src/environment_values.dart';
export 'src/preference_keys.dart';
export 'src/refusal.dart';
export 'src/session_values.dart';
export 'src/workspace_values.dart';
export 'src/worktree_values.dart';
