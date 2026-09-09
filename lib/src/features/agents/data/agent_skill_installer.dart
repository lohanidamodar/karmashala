import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/agent_descriptor.dart';
import '../domain/karmashala_skill.dart';

/// Writes Karmashala's skills into an agent CLI's own skills root, and takes
/// exactly those back out again.
///
/// The story this is built to is the library doc of `agent_skill_support.dart`.
/// Two of its rules are enforced here rather than argued:
///
/// * **A re-install writes nothing.** Every file is read before it is written
///   and skipped when the bytes already match, so the ordinary launch touches
///   the user's home not at all.
/// * **Uninstall removes exactly what was written.** A `SKILL.md` carrying
///   [karmashalaSkillMarker] is deleted, and its directory goes with it only
///   if it is then empty. A file the user put beside ours keeps the directory,
///   which is the difference between removing our skill and removing their
///   folder.
///
/// The skills root itself is left behind either way. It is a directory all
/// three CLIs document and any of them may have created, so deleting it
/// because it is empty would be this app removing something it did not write.
class AgentSkillInstaller {
  const AgentSkillInstaller();

  /// The file every skill directory is identified by.
  static const String fileName = 'SKILL.md';

  /// Where [descriptor] reads skills, given its store home in this
  /// environment — or `null` when it declares no root, or no store to derive
  /// the user's home from.
  ///
  /// The home is the store home with [AgentStoreSpec.homeDirectoryName]'s
  /// segments taken back off, because that is exactly how `CliStoreLocator`
  /// built it. Deriving it is what lets one WSL store home in
  /// `\\wsl.localhost\…` answer for both, without this class knowing which
  /// environment it is in.
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
  /// disk, spelling the bytes this build generates.
  ///
  /// **Read back, never assumed** — the same rule `AgentHookInstaller.install`
  /// was rewritten to follow. A reported install that wrote nothing is worse
  /// than a reported skip, because only the skip gets investigated.
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required List<KarmashalaSkill> skills,
    SkillSweepDeadline? deadline,
  }) async {
    final root = rootFor(descriptor, storeHome);
    if (root == null || skills.isEmpty) return false;
    for (final skill in skills) {
      // Checked before each one rather than once at the top: a sweep is given
      // up on *while* it runs, and the skill after the slow one is the one
      // that would land in a directory nobody owns any more.
      if (deadline?.isAbandoned ?? false) break;
      final file = File(p.join(root, skill.name, fileName));
      try {
        await file.parent.create(recursive: true);
        await _writeIfChanged(file, skill.render(), deadline);
      } on FileSystemException {
        // Someone else's directory, or a share that went away mid-sweep. The
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

  /// The skills whose `SKILL.md` is on disk **right now**, spelling this
  /// build's bytes.
  ///
  /// Separate from [install] because the count is worth reporting on its own:
  /// two of three written is a real state, and `installed: false` with no
  /// number is not enough to act on.
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
  /// whether anything changed.
  ///
  /// Matches on [karmashalaSkillMarker] and never on the directory name, so a
  /// skill of ours the user renamed still goes, and a skill of theirs that
  /// collides with one of our names stays.
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
        // Only when nothing of theirs is left in it. A file the user put
        // beside ours is the difference between removing our skill and
        // removing their folder.
        if (await entry.list(followLinks: false).isEmpty) {
          await entry.delete();
        }
      } on FileSystemException {
        // Left where it is, and reported as still installed next launch.
      }
    }
    return changed;
  }

  /// Written to a staged file and renamed over the real one, so a sweep cut
  /// off mid-flight leaves either the old skill or the new one and never half
  /// a `SKILL.md` for a CLI to discover. It is also why nothing waits for this
  /// at shutdown.
  ///
  /// **The staged write and the rename are one operation.** [deadline] is
  /// checked before the pair and never between them: a future cannot be
  /// cancelled, so the honest guarantee is that an abandoned sweep finishes at
  /// most what was already in flight and starts nothing new. Giving up
  /// *between* the two would leave a `.tmp` beside the skill — litter no CLI
  /// reads, and in a test a file landing in a directory `tearDown` is already
  /// walking, which is the failure this whole gate exists to remove.
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
