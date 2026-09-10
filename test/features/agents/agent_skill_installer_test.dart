import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_agent_reporting/skills.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// What the installer writes into somebody's home, held to the four claims
/// that make writing there defensible at all: exactly these files, a
/// re-install that touches nothing, an uninstall that takes back exactly what
/// it wrote, and an agent with no declared root that gets nothing and says why.
void main() {
  const installer = AgentSkillInstaller();
  const skills = <KarmashalaSkill>[
    KarmashalaSkill(
      name: 'karmashala-one',
      description: 'The first fixture skill. Use it when testing.',
      body: '# One\n\nCall `instructions()`.',
    ),
    KarmashalaSkill(
      name: 'karmashala-two',
      description: 'The second fixture skill. Use it when testing too.',
      body: '# Two\n\nCall `list_agents`.',
    ),
  ];

  final claude = AgentRegistry.builtIn.byId('claudeCode')!;
  final antigravity = AgentRegistry.builtIn.byId('antigravity')!;

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_skills_');
  });
  tearDown(() => removeTempDirectory(home));

  /// The store home the sweep would hand us for [descriptor] under [home].
  String storeHomeFor(AgentDescriptor descriptor) => p.joinAll([
    home.path,
    ...descriptor.store!.homeDirectoryName.split('/'),
  ]);

  List<String> filesUnder(Directory root) =>
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => p.relative(f.path, from: root.path).replaceAll(r'\', '/'))
          .toList()
        ..sort();

  test('install writes exactly one SKILL.md per skill, and nothing else', () async {
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);

    final installed = await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );

    expect(installed, isTrue);
    expect(filesUnder(home), [
      '.claude/skills/karmashala-one/SKILL.md',
      '.claude/skills/karmashala-two/SKILL.md',
    ]);
    final text = File(
      p.join(home.path, '.claude', 'skills', 'karmashala-one', 'SKILL.md'),
    ).readAsStringSync();
    expect(text, startsWith('---\nname: karmashala-one\n'));
    expect(text, contains(karmashalaSkillMarker));
    expect(text, contains('Call `instructions()`.'));
  });

  test('the root follows the CLI, not the store home', () async {
    // Antigravity keeps its sessions in `.gemini/antigravity-cli` and its
    // skills in `.gemini/config`. A root derived from the store home would
    // put ours where `agy` never looks, so this is pinned by path.
    final store = storeHomeFor(antigravity);
    Directory(store).createSync(recursive: true);

    await installer.install(
      descriptor: antigravity,
      storeHome: store,
      skills: skills,
    );

    expect(filesUnder(home), [
      '.gemini/config/skills/karmashala-one/SKILL.md',
      '.gemini/config/skills/karmashala-two/SKILL.md',
    ]);
  });

  test('a re-install touches nothing', () async {
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);
    await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );

    final file = File(
      p.join(home.path, '.claude', 'skills', 'karmashala-one', 'SKILL.md'),
    );
    final before = file.lastModifiedSync();
    // A stamp a filesystem can tell apart from "now", so an unchanged mtime is
    // evidence of no write rather than of a coarse clock.
    file.setLastModifiedSync(before.subtract(const Duration(days: 1)));
    final stamped = file.lastModifiedSync();

    final again = await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );

    expect(again, isTrue);
    expect(file.lastModifiedSync(), stamped);
  });

  test('uninstall removes what it wrote and nothing else', () async {
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);
    await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );

    // Two things of the user's own under the same root: a skill that collides
    // with our naming but carries no marker, and a file inside one of ours.
    final root = p.join(home.path, '.claude', 'skills');
    final theirs = File(p.join(root, 'karmashala-three', 'SKILL.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('---\nname: karmashala-three\n---\nMine.');
    final note = File(p.join(root, 'karmashala-two', 'notes.md'))
      ..writeAsStringSync('kept');

    final changed = await installer.uninstall(
      descriptor: claude,
      storeHome: store,
    );

    expect(changed, isTrue);
    expect(Directory(p.join(root, 'karmashala-one')).existsSync(), isFalse);
    // Ours is gone from it; the directory stays because theirs is still in it.
    expect(note.existsSync(), isTrue);
    expect(File(p.join(root, 'karmashala-two', 'SKILL.md')).existsSync(), isFalse);
    expect(theirs.readAsStringSync(), contains('Mine.'));
    // The root itself is a directory every one of these CLIs documents, so it
    // is left alone whether or not we found it empty.
    expect(Directory(root).existsSync(), isTrue);
  });

  test('a second uninstall changes nothing', () async {
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);
    await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );
    await installer.uninstall(descriptor: claude, storeHome: store);

    expect(
      await installer.uninstall(descriptor: claude, storeHome: store),
      isFalse,
    );
  });

  test('a CLI with no skills root gets nothing, and says why', () async {
    const unsupported = AgentDescriptor(
      id: 'nothing',
      displayName: 'No Skills CLI',
      binaries: AgentBinaries(windows: ['nope'], posix: ['nope']),
      store: AgentStoreSpec(
        homeDirectoryName: '.nope',
        format: AgentStoreFormat.none,
      ),
    );
    final store = storeHomeFor(unsupported);
    Directory(store).createSync(recursive: true);

    expect(installer.rootFor(unsupported, store), isNull);
    expect(
      await installer.install(
        descriptor: unsupported,
        storeHome: store,
        skills: skills,
      ),
      isFalse,
    );
    expect(
      await installer.uninstall(descriptor: unsupported, storeHome: store),
      isFalse,
    );
    expect(filesUnder(home), isEmpty);
    expect(unsupported.skills.isSupported, isFalse);
  });

  test('an edited skill is rewritten, not left as the user left it', () async {
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);
    await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );
    final file = File(
      p.join(home.path, '.claude', 'skills', 'karmashala-one', 'SKILL.md'),
    )..writeAsStringSync('gone');

    expect(
      await installer.installedSkills(
        descriptor: claude,
        storeHome: store,
        skills: skills,
      ),
      {'karmashala-two'},
    );
    await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );
    expect(file.readAsStringSync(), skills.first.render());
  });

  test('a foreign karmashala_ directory under the root is never touched', () async {
    // **The rule, stated as a test.** A sweep may remove what it wrote — by
    // its marker — and nothing else, ever by prefix. The suite itself fills
    // the system temp root with `karmashala_*` directories, and a sweep that
    // matched on a name rather than on a marker would delete other tests'
    // working directories out from under them.
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);
    await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );

    // Three shapes of somebody else's, side by side with ours: a temp
    // directory named the way this suite names them, a directory that shares
    // our prefix exactly, and a skill of the user's own.
    final root = p.join(home.path, '.claude', 'skills');
    final foreignTemp = Directory(p.join(root, 'karmashala_lifecycle_ab12cd34'))
      ..createSync(recursive: true);
    File(p.join(foreignTemp.path, 'settings.json')).writeAsStringSync('{}');
    final foreignPrefixed = Directory(p.join(root, 'karmashala-one-more'))
      ..createSync(recursive: true);
    File(p.join(foreignPrefixed.path, 'SKILL.md')).writeAsStringSync(
      '---\nname: karmashala-one-more\n---\nSomebody else wrote this.',
    );

    await installer.uninstall(descriptor: claude, storeHome: store);

    expect(foreignTemp.existsSync(), isTrue);
    expect(
      File(p.join(foreignTemp.path, 'settings.json')).existsSync(),
      isTrue,
    );
    expect(foreignPrefixed.existsSync(), isTrue);
    expect(
      File(p.join(foreignPrefixed.path, 'SKILL.md')).readAsStringSync(),
      contains('Somebody else wrote this.'),
    );
    // And ours really did go, so this is not passing by doing nothing.
    expect(Directory(p.join(root, 'karmashala-one')).existsSync(), isFalse);
  });

  test('an abandoned sweep writes nothing more', () async {
    // A bounded wait ends the **wait**; a Dart future cannot be cancelled. So
    // an install given up on halfway would go on creating directories under a
    // home nobody owns any more — in the app, somebody's real `~/.claude`
    // after a quit; in the suite, a temp root that has already been torn down.
    // Counted, not timed: the second skill's directory is simply never there.
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);
    final deadline = SkillSweepDeadline()..giveUp();

    final installed = await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
      deadline: deadline,
    );

    expect(installed, isFalse);
    expect(filesUnder(home), isEmpty);
  });

  test('a sweep given up on midway leaves the rest alone', () async {
    final store = storeHomeFor(claude);
    Directory(store).createSync(recursive: true);
    await installer.install(
      descriptor: claude,
      storeHome: store,
      skills: skills,
    );
    // Given up on before the removal starts: nothing of ours goes, which is
    // the same guarantee read from the other direction.
    final deadline = SkillSweepDeadline()..giveUp();

    final changed = await installer.uninstall(
      descriptor: claude,
      storeHome: store,
      deadline: deadline,
    );

    expect(changed, isFalse);
    expect(filesUnder(home), hasLength(2));
  });

  test('the rendered frontmatter is the shape all three CLIs read', () {
    const skill = KarmashalaSkill(
      name: 'karmashala-example',
      description:
          'A description long enough that it has to fold across more than one '
          'line, the way Codex and Antigravity spell their own.',
      body: '# Example',
    );
    final lines = skill.render().split('\n');
    expect(lines.first, '---');
    expect(lines[1], 'name: karmashala-example');
    expect(lines[2], 'description: >-');
    expect(lines[3], startsWith('  '));
    expect(lines, contains('---'));
    expect(skill.render(), contains('<!-- $karmashalaSkillMarker'));
  });
}
