import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';

/// One row a server wrote or removed, as it now stands.
sealed class DataChange {
  const DataChange();

  Map<String, Object?> toJson();

  /// Null for a change this client does not know — a newer server's domain,
  /// which it can safely ignore.
  static DataChange? fromJson(Map<String, Object?> json) =>
      switch (json['change']) {
        'noteChanged' => NoteChanged(
          Note.fromJson((json['note']! as Map).cast<String, Object?>()),
        ),
        'noteRemoved' => NoteRemoved(json['id']! as String),
        'todoChanged' => TodoChanged(
          Todo.fromJson((json['todo']! as Map).cast<String, Object?>()),
        ),
        'todoRemoved' => TodoRemoved(json['id']! as String),
        'preferenceChanged' => PreferenceChanged(
          json['key']! as String,
          json['value'] as String?,
        ),
        'workspaceChanged' => WorkspaceChanged(Workspace.fromJson(_row(json))),
        'workspaceRemoved' => WorkspaceRemoved(json['id']! as String),
        'projectChanged' => ProjectChanged(Project.fromJson(_row(json))),
        'projectRemoved' => ProjectRemoved(json['id']! as String),
        'repositoryChanged' => RepositoryChanged(
          repositoryFromJson(json['row']),
        ),
        'repositoryRemoved' => RepositoryRemoved(json['id']! as String),
        'sectionChanged' => SectionChanged(StoredSection.fromJson(_row(json))),
        'sectionRemoved' => SectionRemoved(json['id']! as String),
        _ => null,
      };
}

final class NoteChanged extends DataChange {
  const NoteChanged(this.note);

  final Note note;

  @override
  Map<String, Object?> toJson() => {
    'change': 'noteChanged',
    'note': note.toJson(),
  };
}

final class NoteRemoved extends DataChange {
  const NoteRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'noteRemoved', 'id': id};
}

final class TodoChanged extends DataChange {
  const TodoChanged(this.todo);

  final Todo todo;

  @override
  Map<String, Object?> toJson() => {
    'change': 'todoChanged',
    'todo': todo.toJson(),
  };
}

final class TodoRemoved extends DataChange {
  const TodoRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'todoRemoved', 'id': id};
}

/// A preference now holding [value], or — null — forgotten.
final class PreferenceChanged extends DataChange {
  const PreferenceChanged(this.key, this.value);

  final String key;
  final String? value;

  @override
  Map<String, Object?> toJson() => {
    'change': 'preferenceChanged',
    'key': key,
    'value': value,
  };
}

/// A workspace-domain row as it now stands, or its id when it went. Each
/// travels as `{change, row}` / `{change, id}`.
sealed class RowChange extends DataChange {
  const RowChange();

  String get name;
}

final class WorkspaceChanged extends RowChange {
  const WorkspaceChanged(this.workspace);

  final Workspace workspace;

  @override
  String get name => 'workspaceChanged';

  @override
  Map<String, Object?> toJson() => {'change': name, 'row': workspace.toJson()};
}

final class ProjectChanged extends RowChange {
  const ProjectChanged(this.project);

  final Project project;

  @override
  String get name => 'projectChanged';

  @override
  Map<String, Object?> toJson() => {'change': name, 'row': project.toJson()};
}

final class RepositoryChanged extends RowChange {
  const RepositoryChanged(this.repository);

  final Repository repository;

  @override
  String get name => 'repositoryChanged';

  @override
  Map<String, Object?> toJson() => {
    'change': name,
    'row': repositoryToJson(repository),
  };
}

final class SectionChanged extends RowChange {
  const SectionChanged(this.section);

  final StoredSection section;

  @override
  String get name => 'sectionChanged';

  @override
  Map<String, Object?> toJson() => {'change': name, 'row': section.toJson()};
}

/// A workspace-domain row that went, by id.
sealed class RowRemoved extends RowChange {
  const RowRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': name, 'id': id};
}

final class WorkspaceRemoved extends RowRemoved {
  const WorkspaceRemoved(super.id);

  @override
  String get name => 'workspaceRemoved';
}

final class ProjectRemoved extends RowRemoved {
  const ProjectRemoved(super.id);

  @override
  String get name => 'projectRemoved';
}

final class RepositoryRemoved extends RowRemoved {
  const RepositoryRemoved(super.id);

  @override
  String get name => 'repositoryRemoved';
}

final class SectionRemoved extends RowRemoved {
  const SectionRemoved(super.id);

  @override
  String get name => 'sectionRemoved';
}

Map<String, Object?> _row(Map<String, Object?> json) =>
    (json['row']! as Map).cast<String, Object?>();

/// Everything one write changed, under the server's [revision] for it.
/// Revisions only grow for the life of one server process, so a copy can
/// tell a late answer from a newer change.
final class DataChanges {
  const DataChanges(this.revision, this.changes);

  final int revision;
  final List<DataChange> changes;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'changes': [for (final change in changes) change.toJson()],
  };

  /// Throws [FormatException] on a batch out of shape.
  static DataChanges fromJson(Map<String, Object?> json) {
    final revision = json['revision'];
    final changes = json['changes'];
    if (revision is! int || changes is! List) {
      throw const FormatException('not a data change batch');
    }
    return DataChanges(revision, [
      for (final change in changes)
        ?DataChange.fromJson((change as Map).cast<String, Object?>()),
    ]);
  }
}
