import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/descriptors.dart';

/// Writes Karmashala's skills into an agent CLI's own skills root, and takes
/// exactly those back out again.
///
/// Two rules of `agent_skill_support.dart` are enforced here rather than argued.
/// **A re-install writes nothing**: every file is read before it is written and
/// skipped when the bytes match. **Uninstall removes exactly what was written**:
/// a `SKILL.md` carrying [karmashalaSkillMarker] goes, and its directory only if
/// it is then empty — a file the user put beside ours keeps the folder.
///
/// The skills root itself is left behind either way: all three CLIs document it
/// and any of them may have created it.
class AgentSkillInstaller {
  const AgentSkillInstaller();

  /// The file every skill directory is identified by.
  static const String fileName = 'SKILL.md';

  /// Where [descriptor] reads skills, given its store home in this environment —
  /// or `null` when it declares no root, or no store to derive the home from.
  ///
  /// The home is the store home with [AgentStoreSpec.homeDirectoryName]'s
  /// segments taken back off, exactly how `CliStoreLocator` built it, which is
  /// what lets one `\\wsl.localhost` store home answer without this class
  /// knowing which environment it is in.
  String? rootFor(AgentDescriptor descriptor, String storeHome) {
    final support = descriptor.skills;
    final store = descriptor.store;
    if (!support.isSupported || store == null) return null;
    var home = storeHome;
    for (final _ in store.homeDirectoryName.split('/')) {
      home = p.dirname(home);
    }
    return p.joinAll(<String>[home, ...support.directorySegments]);
  }

  /// Whether this agent's store exists in [storeHome] at all — the one reason
  /// [install] answers `false` that is not a fault.
  Future<bool> storeIsPresent(String storeHome) =>
      Directory(storeHome).exists();

  /// Writes one directory per skill. Returns whether every one of them is on
  /// disk spelling the bytes this build generates — **read back, never
  /// assumed**, because only a reported skip ever gets investigated.
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required List<KarmashalaSkill> skills,
    SkillSweepDeadline? deadline,
  }) async {
    final root = rootFor(descriptor, storeHome);
    if (root == null || skills.isEmpty) return false;
    for (final skill in skills) {
      // Checked before each one rather than once at the top: a sweep is given up
      // on *while* it runs, and the skill after the slow one is the one that
      // would land in a directory nobody owns any more.
      if (deadline?.isAbandoned ?? false) break;
      final file = File(p.join(root, skill.name, fileName));
      try {
        await file.parent.create(recursive: true);
        await _writeIfChanged(file, skill.render(), deadline);
      } on FileSystemException {
        // Someone else's directory, or a share that went away mid-sweep; the
        // read-back below reports it as an install that did not land.
      }
    }
    if (deadline?.isAbandoned ?? false) return false;
    final present = await installedSkills(
      descriptor: descriptor,
      storeHome: storeHome,
      skills: skills,
    );
    return present.length == skills.length;
  }

  /// The skills whose `SKILL.md` is on disk **right now**, spelling this build's
  /// bytes. Separate from [install] because two of three written is a real state
  /// and `installed: false` with no number is not enough to act on.
  Future<Set<String>> installedSkills({
    required AgentDescriptor descriptor,
    required String storeHome,
    required List<KarmashalaSkill> skills,
  }) async {
    final root = rootFor(descriptor, storeHome);
    if (root == null) return const {};
    final found = <String>{};
    for (final skill in skills) {
      final file = File(p.join(root, skill.name, fileName));
      try {
        if (await file.readAsString() == skill.render()) found.add(skill.name);
      } on FileSystemException {
        // Absent, or unreadable. Either way it will not be discovered.
      }
    }
    return found;
  }

  /// Removes every skill this app wrote under [descriptor]'s root. Returns
  /// whether anything changed. Matches on [karmashalaSkillMarker] and never on
  /// the directory name, so a skill of ours the user renamed still goes and one
  /// of theirs that collides with our name stays.
  Future<bool> uninstall({
    required AgentDescriptor descriptor,
    required String storeHome,
    SkillSweepDeadline? deadline,
  }) async {
    final root = rootFor(descriptor, storeHome);
    if (root == null) return false;
    final directory = Directory(root);
    if (!await directory.exists()) return false;
    var changed = false;
    await for (final entry in directory.list(followLinks: false)) {
      if (deadline?.isAbandoned ?? false) break;
      if (entry is! Directory) continue;
      final file = File(p.join(entry.path, fileName));
      try {
        if (!await file.exists()) continue;
        if (!(await file.readAsString()).contains(karmashalaSkillMarker)) {
          continue;
        }
        await file.delete();
        changed = true;
        // Only when nothing of theirs is left in it: a file the user put beside
        // ours is the difference between removing our skill and their folder.
        if (await entry.list(followLinks: false).isEmpty) {
          await entry.delete();
        }
      } on FileSystemException {
        // Left where it is, and reported as still installed next launch.
      }
    }
    return changed;
  }

  /// Written to a staged file and renamed over the real one, so a sweep cut off
  /// mid-flight leaves either the old skill or the new one and never half a
  /// `SKILL.md` for a CLI to discover.
  ///
  /// [deadline] is checked before the pair and never between them: giving up
  /// *between* the write and the rename would leave a `.tmp` beside the skill —
  /// litter no CLI reads, and in a test a file landing in a directory `tearDown`
  /// is already walking.
  Future<void> _writeIfChanged(
    File file,
    String contents,
    SkillSweepDeadline? deadline,
  ) async {
    try {
      if (await file.readAsString() == contents) return;
    } on FileSystemException {
      // Not there yet, which is the first-install case.
    }
    if (deadline?.isAbandoned ?? false) return;
    final staged = File('${file.path}.tmp');
    await staged.writeAsString(contents, flush: true);
    await staged.rename(file.path);
  }
}
