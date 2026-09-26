/// The workspace domain: contexts, projects, checkouts and saved Explorer
/// sections — the values, their wire shape and the rules every copy of them
/// follows (order, names, where a project's checkouts are). The tables are
/// `store.dart`'s, which only the server imports.
library;

export 'src/domain/project.dart';
export 'src/domain/project_rules.dart';
export 'src/domain/row_json.dart';
export 'src/domain/stored_section.dart';
export 'src/domain/workspace.dart';
