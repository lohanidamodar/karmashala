import 'package:karmashala_notes/karmashala_notes.dart';

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
