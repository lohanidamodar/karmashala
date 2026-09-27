/// The desk end of a phone's link. The server runs it and answers every call
/// itself — from its store, its attention and its screens — whether or not a
/// desktop is open (slice 5c: nothing is forwarded).
library;

export 'src/domain/agent_options.dart';
export 'src/domain/attachment_rules.dart';
export 'src/domain/companion_config.dart';
export 'src/service/agent_records.dart';
export 'src/service/companion_prompts.dart';
export 'src/service/companion_screens.dart';
export 'src/service/host_companion_bindings.dart';
export 'src/service/hosted_session_control.dart';
export 'src/service/hosted_workspace.dart';
export 'src/service/notes_snapshot.dart';
export 'src/service/remote_host_service.dart';
export 'src/service/screen_transcripts.dart';
export 'src/service/sessions_at_rest.dart';
export 'src/service/usage_snapshot.dart';
export 'src/store/companion_attachment_store.dart';
export 'src/store/memory_paired_devices.dart';
export 'src/store/workspace_names.dart';
export 'src/store/workspace_rows.dart';
