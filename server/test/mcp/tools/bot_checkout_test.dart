import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/bot/bot_instructions.dart';
import 'package:karmashala_host/src/mcp/tools/project_folders.dart';
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

  group('in a probe', () {
    late String probeFolder;
    late ProjectFolders probe;

    setUp(() {
      probeFolder = p.join(fixture.path('probe-data'), kBotFolder);
      probe = ProjectFolders(
        fixture.context,
        fixture.reach,
        localHome: fixture.home,
        botFolder: probeFolder,
      );
    });

    String real() => p.join(fixture.home, kKarmashalaFolder, kBotFolder);

    test('it lives under the data folder, and the real one is left', () async {
      final checkout = await probe.createBotCheckout(host());
      expect(checkout.path.path, probeFolder);
      expect(Directory(p.join(probeFolder, '.git')).existsSync(), isTrue);
      expect(File(p.join(probeFolder, kBotMemoryFile)).existsSync(), isTrue);
      expect(Directory(real()).existsSync(), isFalse);
    });

    test('a probe that recorded the real folder moves off it', () async {
      final before = await fixture.folders.createBotCheckout(host());
      final memory = File(p.join(real(), kBotMemoryFile))
        ..writeAsStringSync('what the real bot knows');

      final after = await probe.createBotCheckout(host());

      expect(after.id, before.id);
      expect(after.path.path, probeFolder);
      expect(
        RepositoryDao(fixture.database).getById(before.id)!.path.path,
        probeFolder,
      );
      expect(memory.readAsStringSync(), 'what the real bot knows');
      expect(
        File(p.join(probeFolder, kBotMemoryFile)).readAsStringSync(),
        isEmpty,
      );
    });
  });

  group('botFolderFor', () {
    final data = p.join('data', 'probe');

    test('a real server keeps ~/karmashala/bot', () {
      expect(botFolderFor(const {}, data), isNull);
      expect(botFolderFor(const {'KARMASHALA_PROBE': '0'}, data), isNull);
      expect(botFolderFor(const {'KARMASHALA_PROBE': ''}, data), isNull);
    });

    test(
      'a probe, in every spelling the app accepts, keeps it in its data',
      () {
        for (final word in const ['1', 'true', 'YES', ' on ']) {
          expect(
            botFolderFor({'KARMASHALA_PROBE': word}, data),
            p.join(data, kBotFolder),
            reason: word,
          );
        }
      },
    );
  });

  test('neither a project list nor a checkout list shows it', () async {
    await fixture.folders.createBotCheckout(host());
    expect(RepositoryDao(fixture.database).getPublic(), isEmpty);
    expect(RepositoryDao(fixture.database).getAll().length, 1);
  });
}
