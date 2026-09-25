/// Session lifecycle recorded from host facts: the facts, the status derived
/// from them, the `SessionDao`, and the recorder that applies facts to rows.
library;

export 'src/domain/lifecycle_status.dart';
export 'src/domain/session_facts.dart';
export 'src/service/hosted_session_status_keeper.dart';
export 'src/service/session_lifecycle_recorder.dart';
export 'src/store/session_dao.dart';
export 'src/store/session_placement.dart';
