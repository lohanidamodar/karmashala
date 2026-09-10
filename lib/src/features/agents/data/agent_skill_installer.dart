import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/descriptors.dart';

/// Writes Karmashala's skills into an agent CLI's skills root and takes exactly
/// those back out: a `SKILL.md` carrying [karmashalaSkillMarker], and no more.
class AgentSkillInstaller {
  const AgentSkillInstaller();

  /// The file every skill directory is identified by.
  static const String fileName = 'SKILL.md';

  /// Where [descriptor] reads skills, or `null` when it declares none. Derived
  /// by stripping [AgentStoreSpec.homeDirectoryName] back off the store home.
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

  /// Writes one directory per skill; returns whether every one is on disk
  /// spelling this build's bytes — **read back, never assumed**.
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required List<KarmashalaSkill> skills,
    SkillSweepDeadline? deadline,
  }) async {
    final root = rootFor(descriptor, storeHome);
    if (root == null || skills.isEmpty) return false;
    for (final skill in skills) {
      // Checked before each one, not once at the top: a sweep is given up on
      // *while* it runs, and the next skill would land in nobody's directory.
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

  /// The skills whose `SKILL.md` is on disk **right now**. Separate, because
  /// two of three written is a real state a bare `false` cannot report.
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

  /// Removes every skill this app wrote under [descriptor]'s root. Matches on
  /// [karmashalaSkillMarker], never the directory name, so a rename still goes.
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

  /// Staged and renamed, so a sweep cut off mid-flight never leaves half a
  /// `SKILL.md`; [deadline] is checked before the pair and never between them.
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
