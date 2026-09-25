/// Notes and the todo list: what they are and where they are kept. Read by the
/// desktop's panels and by the session host, which answers a phone's
/// `notes.get` from the same tables while the app is closed.
library;

export 'src/domain/note.dart';
export 'src/domain/todo.dart';
export 'src/store/note_dao.dart';
export 'src/store/todo_dao.dart';
