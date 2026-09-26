/// The automations domain as the services read and write it (the record
/// ports the server's DAOs and a client's copy each implement), its values'
/// wire shape, and the rules a copy follows.
library;

export 'src/domain/automation_json.dart';
export 'src/domain/automation_copy_rules.dart';
export 'src/service/automation_records.dart';
