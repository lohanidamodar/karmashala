import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_snippets/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The snippet and preset tables, and the rules every copy of them follows.
void main() {
  final t0 = DateTime.utc(2026, 9, 1, 12);
  late AppDatabase db;
  late CommandSnippetDao snippets;
  late TerminalPresetDao presets;

  setUp(() {
    db = AppDatabase.memory();
    snippets = CommandSnippetDao(db);
    presets = TerminalPresetDao(db);
  });
  tearDown(() => db.close());

  CommandSnippet snippet({
    String id = 'sn1',
    String label = 'Run the tests',
    String command = 'flutter test --exclude-tags=live-ssh',
    String? shellId,
    bool submit = false,
    DateTime? createdAt,
  }) => CommandSnippet(
    id: id,
    label: label,
    command: command,
    shellId: shellId,
    submit: submit,
    createdAt: createdAt ?? t0,
    updatedAt: createdAt ?? t0,
  );

  group('command_snippets', () {
    test('round-trips every column; an untagged one stores NULL', () {
      snippets.insert(snippet(shellId: 'wsl', submit: true));
      expect(snippets.getById('sn1'), snippet(shellId: 'wsl', submit: true));
      snippets.insert(snippet(id: 'b'));
      final rows = db.query("SELECT shell FROM command_snippets WHERE id='b';");
      expect(rows.single['shell'], isNull);
    });

    test('submit defaults to off in the schema itself', () {
      db.execute(
        'INSERT INTO command_snippets '
        '(id, label, command, created_at, updated_at) VALUES (?, ?, ?, ?, ?);',
        [
          'raw',
          'Deploy',
          'make deploy',
          '2026-01-01T00:00:00.000Z',
          '2026-01-01T00:00:00.000Z',
        ],
      );
      expect(snippets.getById('raw')!.submit, isFalse);
    });

    test(
      'list is insertion order by id at one instant, as compareSnippets',
      () {
        final rows = [
          snippet(id: 'a'),
          snippet(id: 'b', createdAt: t0.add(const Duration(seconds: 1))),
          snippet(id: 'c'),
        ];
        rows.forEach(snippets.insert);
        expect(snippets.list().map((s) => s.id), ['a', 'c', 'b']);
        expect((rows..sort(compareSnippets)).map((s) => s.id), ['a', 'c', 'b']);
        snippets.delete('c');
        expect(snippets.list().map((s) => s.id), ['a', 'b']);
      },
    );

    test('update rewrites what changed, id and creation intact', () {
      snippets.insert(snippet(shellId: 'powerShell'));
      final later = t0.add(const Duration(days: 1));
      snippets.update(
        snippet().copyWith(
          label: 'quiet',
          command: 'make',
          clearShell: true,
          submit: true,
          updatedAt: later,
        ),
      );
      final stored = snippets.getById('sn1')!;
      expect(stored.label, 'quiet');
      expect(stored.shellId, isNull);
      expect(stored.submit, isTrue);
      expect(stored.createdAt, t0);
      expect(stored.updatedAt, later);
    });
  });

  group('the rules', () {
    test('a tag is compared as a string: an unknown one matches nothing', () {
      expect(snippet().fitsShell('wsl'), isTrue);
      expect(snippet().fitsShell(null), isTrue);
      expect(snippet(shellId: 'wsl').fitsShell('wsl'), isTrue);
      expect(snippet(shellId: 'wsl').fitsShell('powerShell'), isFalse);
      expect(snippet(shellId: 'powerShell').fitsShell(null), isFalse);
      expect(snippet(shellId: 'nushell').fitsShell('wsl'), isFalse);
    });

    test('a snippet is one line, and needs a label and a command', () {
      expect(singleLine('git add -A\ngit commit'), 'git add -A git commit');
      expect(singleLine('  make build \r\n'), 'make build');
      expect(snippetProblem(label: ' ', command: 'x'), isNotNull);
      expect(snippetProblem(label: 'x', command: '\n'), isNotNull);
      expect(snippetProblem(label: 'x', command: 'y'), isNull);
    });

    test('JSON round-trips a snippet, and refuses one out of shape', () {
      final s = snippet(shellId: 'ssh', submit: true);
      expect(CommandSnippet.fromJson(s.toJson()), s);
      expect(
        () => CommandSnippet.fromJson(const {'id': 1}),
        throwsFormatException,
      );
    });
  });

  group('terminal_presets', () {
    StoredPreset preset(String id, String name, DateTime at) => StoredPreset(
      id: id,
      name: name,
      shape: const {
        'tabs': [
          {'panes': []},
        ],
        'active': 0,
      },
      updatedAt: at,
    );

    test('saved last first; a re-save keeps the id', () {
      presets
        ..save(preset('p1', 'one', t0))
        ..save(preset('p2', 'two', t0.add(const Duration(minutes: 1))));
      expect(presets.getAll().map((p) => p.id), ['p2', 'p1']);
      presets.save(preset('p1', 'one', t0.add(const Duration(hours: 1))));
      expect(presets.getAll().map((p) => p.id), ['p1', 'p2']);
      expect(presets.byId('p1')!.shape['active'], 0);
      final all = presets.getAll();
      expect(([...all]..sort(comparePresets)).map((p) => p.id), ['p1', 'p2']);
      presets.delete('p1');
      expect(presets.byId('p1'), isNull);
    });

    test('a shape that is not JSON is skipped rather than thrown on', () {
      presets.save(preset('p1', 'one', t0));
      db.execute("UPDATE terminal_presets SET shape = '{nope' WHERE id='p1';");
      expect(presets.getAll(), isEmpty);
    });

    test('a name already saved keeps its id', () {
      final saved = [preset('p1', 'one', t0)];
      expect(presetIdFor('one', 'new', saved), 'p1');
      expect(presetIdFor('two', 'new', saved), 'new');
    });
  });
}
