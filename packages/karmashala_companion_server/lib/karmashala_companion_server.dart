/// The desk end of a phone's link. The session host runs the server and
/// answers from the store and its screens; a connected desktop app answers
/// what only it can, over calls the host forwards. Where there is no host, the
/// app runs the same server itself.
library;

export 'src/domain/companion_config.dart';
export 'src/protocol/companion_call_dispatcher.dart';
export 'src/protocol/companion_method.dart';
export 'src/protocol/forwarded_bindings.dart';
export 'src/service/companion_app_link.dart';
export 'src/service/companion_screens.dart';
export 'src/service/host_companion_bindings.dart';
export 'src/service/notes_snapshot.dart';
export 'src/service/remote_host_service.dart';
export 'src/service/screen_transcripts.dart';
export 'src/service/sessions_at_rest.dart';
export 'src/store/companion_config_store.dart';
export 'src/store/host_identity.dart';
export 'src/store/workspace_names.dart';
