import 'package:riverpod/riverpod.dart';

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

/// One machine behind the active desktop, as the phone lists it.
class CompanionEnvironment {
  const CompanionEnvironment({
    required this.key,
    required this.label,
    required this.kind,
    required this.projects,
    required this.sessions,
  });

  /// What groups the rows: the desktop's own environment id when it sent one,
  /// otherwise the name it badged them with. **Never derived from both** — a
  /// key that changed shape between desktops would split one machine in two.
  final String key;

  final String label;

  /// `wsl`, `ssh`, `windowsNative`, `localPosix` — or null from a desktop that
  /// does not send it, where the glyph stays neutral rather than guessed.
  final String? kind;

  final int projects;
  final int sessions;
}

/// The machines the phone can see behind one desktop, local first.
///
/// Counted from the **workspace** where the desktop sent one, so a machine
/// holding projects nobody has started a session on is still a machine you can
/// go to. Sessions add their own counts, and may name a machine the workspace
/// did not — an older desktop, or a project since removed.
///
/// **Empty means the desktop has said nothing yet**, not that it runs nothing —
/// the caller shows the snapshot's age rather than an empty list (§19). A
/// single machine is still returned; deciding to skip the step is the screen's,
/// and it needs the one row's name to say where it landed.
List<CompanionEnvironment> companionEnvironments(
  List<CompanionSessionSummary> sessions, {
  List<RemoteWorkspaceProject> projects = const [],
}) {
  final byKey = <String, _Tally>{};

  for (final project in projects) {
    final key = project.environmentId ?? project.environmentBadge;
    // A project the desktop placed nowhere belongs to no machine we can name.
    if (key == null || key.isEmpty) continue;
    byKey
        .putIfAbsent(
          key,
          () => _Tally(
            label: project.environmentBadge ?? project.environmentName ?? key,
            kind: project.environmentKind,
          ),
        )
        .projects
        .add(project.projectId);
  }

  for (final session in sessions) {
    final key = session.environmentId ?? session.environmentBadge;
    // A session the desktop said nothing about belongs to no machine we can
    // name. Counting it under "this one" would be a guess.
    if (key == null || key.isEmpty) continue;
    final tally = byKey.putIfAbsent(
      key,
      () => _Tally(
        label: session.environmentBadge ?? key,
        kind: session.environmentKind,
      ),
    );
    tally.sessions++;
    final project = session.projectId;
    if (project != null) tally.projects.add(project);
  }

  final out = [
    for (final entry in byKey.entries)
      CompanionEnvironment(
        key: entry.key,
        label: entry.value.label,
        kind: entry.value.kind,
        projects: entry.value.projects.length,
        sessions: entry.value.sessions,
      ),
  ]..sort((a, b) {
    final rank = _rank(a.kind).compareTo(_rank(b.kind));
    if (rank != 0) return rank;
    return a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return out;
}

/// The sessions on one machine, by the same key [companionEnvironments] groups
/// on.
List<CompanionSessionSummary> sessionsOnEnvironment(
  List<CompanionSessionSummary> sessions,
  String key,
) => [
  for (final session in sessions)
    if ((session.environmentId ?? session.environmentBadge) == key) session,
];

/// Local, then WSL, then SSH, then a machine whose kind the desktop did not
/// say — the order the desktop's own Explorer uses.
int _rank(String? kind) => switch (kind) {
  'windowsNative' || 'localPosix' => 0,
  'wsl' => 1,
  'ssh' => 2,
  _ => 3,
};

class _Tally {
  _Tally({required this.label, required this.kind});
  final String label;
  final String? kind;
  final projects = <String>{};
  var sessions = 0;
}


/// The machine the phone has narrowed to, by [CompanionEnvironment.key], or
/// null for "all of them".
///
/// In memory: it is where you are looking, not where you live, and a key from
/// a desktop you have since switched away from names nothing. The screen
/// treats a key it cannot find as "all of them" rather than showing an empty
/// list, so switching desktops needs no listener here.
class CompanionEnvironmentChoice extends Notifier<String?> {
  @override
  String? build() => null;

  void choose(String? key) => state = key;
}

final companionEnvironmentProvider =
    NotifierProvider<CompanionEnvironmentChoice, String?>(
      CompanionEnvironmentChoice.new,
    );
