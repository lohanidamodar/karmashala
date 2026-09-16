import '../domain/note.dart';

/// Where [note] came from, in the words of what is still true: a session that
/// has since been deleted is said to be gone rather than dropped.
String noteProvenance(Note note, String? sessionTitle) {
  if (note.sourceSessionId == null) return 'Written here';
  final role = switch (note.sourceMessageRole) {
    'user' => 'your message',
    'agent' => 'the agent’s reply',
    _ => 'a message',
  };
  if (sessionTitle == null) return 'From a session that is gone  ·  $role';
  return 'From $sessionTitle  ·  $role';
}
