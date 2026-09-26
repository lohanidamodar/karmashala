/// The sessions domain's rules, for the server and every client: host facts
/// and the lifecycle status derived from them, the reads every reader of the
/// sessions table asks (`SessionReads`, and `SessionRowsIndex` over a copy),
/// what each change a client may ask does to a row (`SessionEdits`), the
/// imported-history rules and the follow-up policy. No store: the DAOs and
/// the services that write through them are `store.dart`, the server's alone.
library;

export 'src/domain/follow_up_policy.dart';
export 'src/domain/imported_rules.dart';
export 'src/domain/lifecycle_status.dart';
export 'src/domain/session_facts.dart';
export 'src/domain/session_placement_rule.dart';
export 'src/domain/session_reads.dart';
export 'src/service/hosted_session_status_keeper.dart';
export 'src/service/session_lifecycle_recorder.dart';
