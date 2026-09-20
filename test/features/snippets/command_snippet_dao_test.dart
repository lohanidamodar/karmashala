import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/snippets/data/command_snippet_dao.dart';
import 'package:karmashala/src/features/snippets/domain/command_snippet.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fixtures.dart';

/// The snippet store and the one rule that decides where a snippet is offered.
///
/// The rule is compared as **strings** on purpose (see [CommandSnippet]), and
/// the cases below are the reason: a tag this build cannot resolve has to match
/// nothing rather than everything, and an enum decoded with a fallback cannot
/// say that.
void main() {
  late AppDatabase db;
  late CommandSnippetDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = CommandSnippetDao(db);
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
    createdAt: createdAt ?? testTime,
    updatedAt: createdAt ?? testTime,
  );

  group('the v32 table', () {
    test('a fresh database has it, and round-trips every column', () {
      dao.insert(snippet(shellId: 'wsl', submit: true));

      final stored = dao.getById('sn1')!;
      expect(stored.label, 'Run the tests');
      expect(stored.command, 'flutter test --exclude-tags=live-ssh');
      expect(stored.shellId, 'wsl');
      expect(stored.shell, TerminalShell.wsl);
      expect(stored.submit, isTrue);
      expect(stored.createdAt, testTime);
    });

    test('an untagged snippet stores NULL, not an empty string', () {
      dao.insert(snippet());

      // The distinction the filter turns on: NULL is "any shell", and '' would
      // be a tag matching no shell at all.
      final rows = db.query('SELECT shell FROM command_snippets;');
      expect(rows.single['shell'], isNull);
      expect(dao.getById('sn1')!.shellId, isNull);
    });

    test('submit defaults to off in the schema itself', () {
      // Written straight past the DAO, the way a future migration or a hand
      // edit would. The default is the safe act.
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

      expect(dao.getById('raw')!.submit, isFalse);
    });

    test('list is insertion order, and a delete removes exactly one', () {
      dao
        ..insert(snippet(id: 'a', label: 'First'))
        ..insert(
          snippet(
            id: 'b',
            label: 'Second',
            createdAt: testTime.add(const Duration(seconds: 1)),
          ),
        )
        // Same instant as `a`: the id is what keeps the order defined.
        ..insert(snippet(id: 'c', label: 'Third'));

      expect(dao.list().map((s) => s.id), ['a', 'c', 'b']);

      dao.delete('c');
      expect(dao.list().map((s) => s.id), ['a', 'b']);
    });

    test('update rewrites what the user changed, id and creation intact', () {
      dao.insert(snippet(shellId: 'powerShell'));
      final later = testTime.add(const Duration(days: 1));

      dao.update(
        'sn1',
        label: 'Run the tests, quietly',
        command: 'flutter test -r compact',
        shellId: null,
        submit: true,
        updatedAt: later,
      );

      final stored = dao.getById('sn1')!;
      expect(stored.label, 'Run the tests, quietly');
      expect(stored.command, 'flutter test -r compact');
      expect(stored.shellId, isNull, reason: 'a tag can be taken back off');
      expect(stored.submit, isTrue);
      expect(stored.createdAt, testTime);
      expect(stored.updatedAt, later);
    });
  });

  group('the shell filter', () {
    test('an untagged snippet fits every pane, including an unknown one', () {
      final any = snippet();

      for (final shell in TerminalShell.values) {
        expect(any.fitsShell(shell.name), isTrue);
      }
      expect(any.fitsShell(null), isTrue);
    });

    test('a tagged snippet fits only that shell', () {
      final wsl = snippet(shellId: 'wsl');

      expect(wsl.fitsShell('wsl'), isTrue);
      expect(wsl.fitsShell('powerShell'), isFalse);
      expect(wsl.fitsShell('commandPrompt'), isFalse);
      expect(wsl.fitsShell('posix'), isFalse);
    });

    test('a pane whose shell is unknown is offered only untagged ones', () {
      // A pane restored from a profile id this build no longer resolves. It
      // gets the snippets that claim nothing, rather than the ones that claim
      // something we cannot check.
      expect(snippet().fitsShell(null), isTrue);
      expect(snippet(shellId: 'powerShell').fitsShell(null), isFalse);
    });

    test('a tag from a newer build matches nothing rather than everything', () {
      final future = snippet(shellId: 'nushell');

      expect(future.hasUnknownShell, isTrue);
      expect(future.shell, isNull);
      for (final shell in TerminalShell.values) {
        expect(
          future.fitsShell(shell.name),
          isFalse,
          reason: 'an unresolvable tag must never fall back to "any shell"',
        );
      }
    });

    test('an SSH environment contributes a real SSH pane and tag', () {
      final profiles = terminalProfilesFor([
        windowsEnv(),
        sshEnvFixture(),
        wslEnv(distro: 'Ubuntu'),
      ]);

      expect(profiles.map((p) => p.shell).toSet(), {
        TerminalShell.powerShell,
        TerminalShell.commandPrompt,
        TerminalShell.wsl,
        TerminalShell.ssh,
      });
      expect(TerminalShell.values, hasLength(5));
      expect(shellTagLabel(TerminalShell.ssh.name), 'SSH');
    });
  });

  group('a snippet is one line', () {
    test('newlines are flattened, so nothing submits by accident', () {
      // A stored newline is a submit: a PTY reads CR as "run this", so the
      // first line of a two-line snippet would run whatever `submit` says.
      expect(singleLine('git add -A\ngit commit'), 'git add -A git commit');
      expect(singleLine('  make build \r\n'), 'make build');
    });
  });
}
