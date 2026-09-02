import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:karmashala/src/features/explorer/data/explorer_section_dao.dart';
import 'package:karmashala/src/features/explorer/domain/explorer_section.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v29* database can be populated and then migrated — the same
/// helper `notes_migration_test.dart` uses, for the same reason.
Database _migratedTo(int upTo) {
  final db = sqlite3.openInMemory();
  final versions = schemaMigrations.keys.where((v) => v <= upTo).toList()
    ..sort();
  for (final version in versions) {
    schemaMigrations[version]!(db);
    db.execute('PRAGMA user_version = $version;');
  }
  return db;
}

void main() {
  group('v29', () {
    test('seeds Pinned and three suggestions, all folded shut', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final sections = ExplorerSectionDao(db).getAll();

      expect(
        [for (final s in sections) s.name],
        ['Pinned', 'Checks failing', 'Awaiting input', 'Ended in failure'],
        reason:
            'the seeded order is the severity order a fixed priority table '
            'would have imposed — expressed as something the user can drag',
      );
      expect(sections.first.id, kPinnedSectionId);
      expect(sections.first.rule, isA<PinnedRule>());
      expect(sections.first.isEditable, isFalse);
      expect(
        [for (final s in sections) s.collapsed],
        everyElement(isTrue),
        reason:
            'a workspace that upgrades into this feature and never opens a '
            'section must pay nothing for it',
      );
      expect([for (final s in sections) s.position], [0, 1, 2, 3]);
    });

    test('adds its tables to an existing database without touching it', () {
      final db = _migratedTo(28);
      addTearDown(db.close);
      db.execute('PRAGMA foreign_keys = OFF;');
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, status, created_at) '
        "VALUES ('s-1', 'r-1', 'i-1', 'Old session', 0, 'failed', "
        "'2026-08-01T00:00:00.000Z');",
      );

      schemaMigrations[29]!(db);
      db.execute('PRAGMA user_version = 29;');

      expect(
        db
            .select("SELECT title FROM sessions WHERE id = 's-1';")
            .single['title'],
        'Old session',
      );
      // The session predates the feature and already says `failed`. It is
      // **not** enrolled anywhere by the migration: the seeded groups are rule
      // sections, so what is in them is decided live and never written down.
      expect(db.select('SELECT * FROM explorer_section_members;'), isEmpty);
      expect(db.select('SELECT * FROM explorer_sections;').length, 4);
    });

    test('re-running the step is safe', () {
      final db = _migratedTo(29);
      addTearDown(db.close);
      schemaMigrations[29]!(db);
      expect(db.select('SELECT * FROM explorer_sections;').length, 4);
    });
  });

  group('the DAO', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    test('round-trips a glob section, pattern and all', () {
      final dao = ExplorerSectionDao(db);
      dao.insert(
        ExplorerSection(
          id: 'x',
          name: 'Releases',
          rule: BranchGlobRule('release/*'),
          position: 9,
          collapsed: false,
        ),
      );

      final section = dao.getAll().last;
      expect(section.name, 'Releases');
      expect(section.rule.pattern, 'release/*');
      expect(section.collapsed, isFalse);
      expect(
        section.rule.matches(
          const SectionFacts(
            id: 's',
            title: 't',
            imported: false,
            branch: 'release/1',
          ),
        ),
        isTrue,
        reason: 'a rule read back from SQLite must still match',
      );
    });

    test('stores members for a hand-filled group and only for one', () {
      final dao = ExplorerSectionDao(db);
      dao.insert(
        const ExplorerSection(
          id: 'mine',
          name: 'Mine',
          rule: ManualRule(),
          position: 9,
          members: {'s1', 's2'},
        ),
      );
      // A rule section handed a member list writes nothing: membership is not
      // a fact about a rule section, and a stored copy would be a second answer
      // that goes stale the moment a check turns red.
      dao.insert(
        const ExplorerSection(
          id: 'red',
          name: 'Red',
          rule: ChecksFailingRule(),
          position: 10,
          members: {'s3'},
        ),
      );

      final byId = {for (final s in dao.getAll()) s.id: s};
      expect(byId['mine']!.members, {'s1', 's2'});
      expect(byId['red']!.members, isEmpty);

      dao.removeMember('mine', 's1');
      dao.addMember('mine', 's9');
      expect({for (final s in dao.getAll()) s.id: s}['mine']!.members, {
        's2',
        's9',
      });
    });

    test('deleting a section takes its members with it', () {
      final dao = ExplorerSectionDao(db);
      dao.insert(
        const ExplorerSection(
          id: 'mine',
          name: 'Mine',
          rule: ManualRule(),
          position: 9,
          members: {'s1'},
        ),
      );
      dao.delete('mine');
      expect(db.query('SELECT * FROM explorer_section_members;'), isEmpty);
    });

    test('reorder renumbers, and collapse writes one bit', () {
      final dao = ExplorerSectionDao(db);
      final before = dao.getAll();
      dao.reorder([before[0].id, before[3].id, before[1].id, before[2].id]);
      expect(
        [for (final s in dao.getAll()) s.name],
        ['Pinned', 'Ended in failure', 'Checks failing', 'Awaiting input'],
      );

      dao.setCollapsed(kPinnedSectionId, false);
      expect(dao.getAll().first.collapsed, isFalse);
    });

    test('a row whose rule this build cannot read is skipped, not guessed', () {
      // What a downgrade looks like: a newer build wrote a rule kind this one
      // has no code for. Drawing it as a manual group would silently strip the
      // rule the moment the user renamed it.
      db.execute(
        'INSERT INTO explorer_sections (id, name, kind, pattern, position, '
        "collapsed) VALUES ('future', 'From tomorrow', 'blocksMerge', NULL, "
        '99, 1);',
      );
      final ids = [for (final s in ExplorerSectionDao(db).getAll()) s.id];
      expect(ids, isNot(contains('future')));
      expect(ids.length, 4);
    });
  });
}
