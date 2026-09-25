import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show notesSnapshot;
import 'package:karmashala_remote/remote.dart';
import 'package:riverpod/riverpod.dart';

import '../../notes/application/notes_providers.dart';
import '../../projects/application/project_providers.dart';
import '../../todos/application/todos_providers.dart';

/// The desktop's notes and todo list, for `notes.get` — the same builder the
/// session host answers with, over this app's providers.
Future<RemoteNotesSnapshot> remoteNotesSnapshot(Ref ref) async => notesSnapshot(
  notes: ref.read(noteDaoProvider),
  todos: ref.read(todoDaoProvider),
  projectNames: {
    for (final project in ref.read(projectDaoProvider).getAll())
      project.id: project.name,
  },
  notesEnabled: ref.read(notesEnabledProvider),
);
