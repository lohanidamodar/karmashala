import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_remote/remote.dart';

/// The desktop's notes and todo list, for `notes.get`: notes newest first and
/// todos in the panel's own order, each capped so the answer fits one frame.
/// Notes switched off are not sent, and the answer says so.
///
/// One builder for the session host and the app, over the same lists, so the
/// phone reads the same list whichever of the two answers it.
RemoteNotesSnapshot notesSnapshot({
  required List<Note> notes,
  required List<Todo> todos,
  required Map<String, String> projectNames,
  required bool notesEnabled,
}) {
  final noteRows = notesEnabled ? notes : const <Note>[];
  final todoRows = todos;
  return RemoteNotesSnapshot(
    notesEnabled: notesEnabled,
    notes: [
      for (final note in noteRows.take(kMaxRemoteNotes))
        RemoteNote.bounded(
          id: note.id,
          title: note.displayTitle,
          body: note.body,
          updatedAt: note.updatedAt,
          projectName: projectNames[note.projectId],
        ),
    ],
    todos: [
      for (final todo in todoRows.take(kMaxRemoteTodos))
        RemoteTodo(
          id: todo.id,
          body: todo.body,
          done: todo.isDone,
          projectName: projectNames[todo.projectId],
        ),
    ],
    omittedNotes: noteRows.length > kMaxRemoteNotes
        ? noteRows.length - kMaxRemoteNotes
        : 0,
    omittedTodos: todoRows.length > kMaxRemoteTodos
        ? todoRows.length - kMaxRemoteTodos
        : 0,
  );
}
