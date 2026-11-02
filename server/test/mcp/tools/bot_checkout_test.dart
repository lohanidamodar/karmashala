import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/bot/bot_instructions.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// The bot's folder, `~/karmashala/bot`: a real git repository, because
/// checkpoints need one, under a hidden project, with the bot's instructions
/// and its lasting memory.
void main() {
  late RepoToolFixture fixture;

  setUp(() => fixture = RepoToolFixture());
  tearDown(() => fixture.dispose());

  ExecutionEnvironment host() => fixture.reach.host!;

  test('is made, git inited, and recorded under a hidden project', () async {
    final checkout = await fixture.folders.createBotCheckout(host());
    expect(p.basename(checkout.path.path), 'bot');
    expect(Directory(p.join(checkout.path.path, '.git')).existsSync(), isTrue);
    final project = ProjectDao(fixture.database).getById(checkout.projectId)!;
    expect(project.isBot, isTrue);
    expect(project.kind, Project.botKind);
  });

  test('is given its instructions, and they stay out of git', () async {
    final checkout = await fixture.folders.createBotCheckout(host());
    final root = checkout.path.path;
    expect(
      File(p.join(root, 'AGENTS.md')).readAsStringSync(),
      contains('Karmashala bot'),
    );
    expect(File(p.join(root, 'CLAUDE.md')).readAsStringSync(), '@AGENTS.md\n');
    expect(File(p.join(root, kBotMemoryFile)).readAsStringSync(), isEmpty);
    final excluded = File(
      p.join(root, '.git', 'info', 'exclude'),
    ).readAsStringSync();
    for (final name in ['AGENTS.md', 'CLAUDE.md', kBotMemoryFile]) {
      expect(excluded, contains(name));
    }
  });

  test('a second call is the same checkout, and keeps MEMORY.md', () async {
    final first = await fixture.folders.createBotCheckout(host());
    final memory = File(p.join(first.path.path, kBotMemoryFile))
      ..writeAsStringSync('The person calls it the shop.');
    File(
      p.join(first.path.path, 'AGENTS.md'),
    ).writeAsStringSync('an older build wrote this');
    final second = await fixture.folders.createBotCheckout(host());
    expect(second.id, first.id);
    expect(memory.readAsStringSync(), 'The person calls it the shop.');
    expect(
      File(p.join(first.path.path, 'AGENTS.md')).readAsStringSync(),
      contains('Karmashala bot'),
    );
    expect(
      RepositoryDao(fixture.database).getByProject(first.projectId).length,
      1,
    );
  });

  test('neither a project list nor a checkout list shows it', () async {
    await fixture.folders.createBotCheckout(host());
    expect(RepositoryDao(fixture.database).getPublic(), isEmpty);
    expect(RepositoryDao(fixture.database).getAll().length, 1);
  });
}
