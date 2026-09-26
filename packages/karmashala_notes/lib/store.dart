/// The `notes` and `todos` tables. The server's: a client reads and writes
/// them through its data API, never here.
library;

export 'src/store/note_dao.dart';
export 'src/store/todo_dao.dart';
