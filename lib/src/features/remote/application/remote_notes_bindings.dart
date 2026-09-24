import 'package:karmashala_remote/remote.dart';
import 'package:riverpod/riverpod.dart';

import '../../notes/application/notes_providers.dart';
import '../../projects/application/project_providers.dart';
import '../../todos/application/todos_providers.dart';

/// The desktop's notes and todo list, for `notes.get`: notes newest first and
/// todos in the panel's own order, each capped so the answer fits one frame.
/// Notes switched off in Settings are not sent, and the answer says so.
Future<RemoteNotesSnapshot> remoteNotesSnapshot(Ref ref) async {
  final projects = {
    for (final project in ref.read(projectDaoProvider).getAll())
      project.id: project.name,
  };
  final notesEnabled = ref.read(notesEnabledProvider);
  final notes = notesEnabled
      ? ref.read(noteDaoProvider).list()
      : const <Never>[];
  final todos = ref.read(todoDaoProvider).list();
  return RemoteNotesSnapshot(
    notesEnabled: notesEnabled,
    notes: [
      for (final note in notes.take(kMaxRemoteNotes))
        RemoteNote.bounded(
          id: note.id,
          title: note.displayTitle,
          body: note.body,
          updatedAt: note.updatedAt,
          projectName: projects[note.projectId],
        ),
    ],
    todos: [
      for (final todo in todos.take(kMaxRemoteTodos))
        RemoteTodo(
          id: todo.id,
          body: todo.body,
          done: todo.isDone,
          projectName: projects[todo.projectId],
        ),
    ],
    omittedNotes: notes.length > kMaxRemoteNotes
        ? notes.length - kMaxRemoteNotes
        : 0,
    omittedTodos: todos.length > kMaxRemoteTodos
        ? todos.length - kMaxRemoteTodos
        : 0,
  );
}
