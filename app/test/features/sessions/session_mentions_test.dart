import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_mention_reads.dart';
import 'package:karmashala/src/features/sessions/application/session_mentions.dart';
import 'package:karmashala/src/features/sessions/domain/composer_mentions.dart';
import 'package:karmashala_session/mentions.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

class _FakeReads implements MentionReads {
  List<String> files_ = const [
    'app/lib/main.dart',
    'app/lib/src/composer.dart',
    'app/build/out.txt',
    'README.md',
    'Makefile',
    'secrets.env',
  ];
  String? gitignore = 'build/\n*.env\n';
  final diffs = <String>[];
  String diffText = '--- a/x\n+++ b/x\n+new\n';
  final tails = <String, String>{'t1': 'line 1\nline 2'};

  @override
  Future<({List<String> files, String? gitignore})> files() async =>
      (files: files_, gitignore: gitignore);

  @override
  Future<String> diff(String base) async {
    diffs.add(base);
    return diffText;
  }

  @override
  List<MentionTerminal> terminals() => const [
    MentionTerminal(id: 't1', title: 'Build server', detail: '~/app'),
    MentionTerminal(id: 't2', title: 'zsh'),
  ];

  @override
  String? terminalTail(String id, int lines) => tails[id];

  @override
  List<MentionSession> sessions() => const [
    MentionSession(id: 's2', title: 'Fix login'),
    MentionSession(id: 's3', title: 'Release notes'),
  ];

  @override
  List<MentionSession> subagents() => const [
    MentionSession(id: 's4', title: 'round 1'),
  ];

  @override
  Future<String?> lastAnswer(String id) async => 'answer of $id';
}

List<String> _inserts(List<ComposerMentionOption> options) => [
  for (final o in options) o.insert,
];

void main() {
  late _FakeReads reads;
  late SessionMentions mentions;

  setUp(() {
    reads = _FakeReads();
    mentions = SessionMentions(reads);
  });

  group('options', () {
    test('"@" alone offers the kinds, then files and folders', () async {
      final options = await mentions.options('');
      expect(_inserts(options).take(5), [
        '@diff',
        '@diff:',
        '@terminal:',
        '@session:',
        '@subagent:',
      ]);
      expect(options[2].continues, isTrue);
      final inserts = _inserts(options);
      expect(inserts, contains('@app/lib/main.dart'));
      expect(inserts, contains('@app/lib/'));
      expect(inserts, contains('@./Makefile'));
    });

    test('typing narrows to matching kinds and files; ignored ones never '
        'show', () async {
      final options = await mentions.options('comp');
      expect(_inserts(options), contains('@app/lib/src/composer.dart'));
      expect(_inserts(options), isNot(contains('@diff')));

      final all = _inserts(await mentions.options(''));
      expect(all.where((i) => i.contains('build')), isEmpty);
      expect(all, isNot(contains('@secrets.env')));

      expect(_inserts(await mentions.options('te')), contains('@terminal:'));
    });

    test('a kind lists its own entries, filtered', () async {
      expect(_inserts(await mentions.options('terminal:bui')), [
        '@terminal:"Build server"',
      ]);
      expect(_inserts(await mentions.options('session:')), [
        '@session:"Fix login"',
        '@session:"Release notes"',
      ]);
      expect(_inserts(await mentions.options('subagent:')), [
        '@subagent:"round 1"',
      ]);
      expect(_inserts(await mentions.options('diff:dev')), [
        '@diff',
        '@diff:dev',
        '@diff:main',
      ]);
      expect(_inserts(await mentions.options('diff:--output=x')), [
        '@diff',
        '@diff:main',
      ]);
    });

    test('a link is offered as itself', () async {
      final options = await mentions.options('https://example.com/a');
      expect(options.single.kind, MentionKind.url);
      expect(options.single.insert, '@https://example.com/a');
    });
  });

  group('expand', () {
    test('files and links stay as written; nothing is added', () async {
      const text = 'Look at @app/lib/main.dart and @https://x.dev';
      expect(await mentions.expand(text), text);
    });

    test(
      'a diff is the uncommitted changes, or the branch since a base',
      () async {
        final sent = await mentions.expand('Review @diff and @diff:main');
        expect(reads.diffs, ['HEAD', 'main...HEAD']);
        expect(sent, contains('@diff — uncommitted changes:\n```diff\n'));
        expect(
          sent,
          contains('@diff:main — this branch’s commits since main:'),
        );
      },
    );

    test('a terminal is its last lines; a session its last answer', () async {
      final sent = await mentions.expand(
        'See @terminal:"Build server", @session:"Fix login" and '
        '@subagent:"round 1"',
      );
      expect(
        sent,
        contains(
          '@terminal:"Build server" — last 200 lines of Build server:\n'
          '```text\nline 1\nline 2\n```',
        ),
      );
      expect(sent, contains('answer of s2'));
      expect(sent, contains('the report of sub-session round 1'));
      expect(sent, contains('answer of s4'));
      final read = splitMentionedMessage(sent);
      expect(read.sections, hasLength(3));
    });

    test('the same mention twice is sent once', () async {
      final sent = await mentions.expand('@diff then @diff again');
      expect(reads.diffs, ['HEAD']);
      expect(splitMentionedMessage(sent).sections, hasLength(1));
    });

    test('a long diff is capped and says it was cut', () async {
      reads.diffText = List.filled(5000, '+a line of the diff').join('\n');
      final sent = await mentions.expand('@diff');
      expect(sent, contains('showing the first'));
      final body = splitMentionedMessage(sent).sections.single.body;
      expect(body.length, lessThanOrEqualTo(kMentionContextCap));
    });

    test('a terminal or session that is not there refuses the send', () async {
      expect(
        () => mentions.expand('@terminal:gone'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => mentions.expand('@session:"No such"'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('GitignoreRules', () {
    test('globs, folders, anchors and negation', () {
      final rules = GitignoreRules.parse(
        '# comment\n'
        'build/\n'
        '*.log\n'
        '/top.txt\n'
        'docs/**/draft.md\n'
        '!keep.log\n',
      );
      expect(rules.ignores('app/build/x.dart'), isTrue);
      expect(rules.ignores('build'), isFalse);
      expect(rules.ignores('a/b/c.log'), isTrue);
      expect(rules.ignores('keep.log'), isFalse);
      expect(rules.ignores('top.txt'), isTrue);
      expect(rules.ignores('sub/top.txt'), isFalse);
      expect(rules.ignores('docs/a/b/draft.md'), isTrue);
      expect(rules.ignores('docs/draft.md'), isTrue);
      expect(rules.ignores('lib/main.dart'), isFalse);
    });
  });

  group('files through the server', () {
    late TestMachine db;
    late FakeDataServer server;
    late Directory disk;

    setUp(() {
      db = TestMachine();
      server = FakeDataServer()..runsOn(db);
      disk = Directory.systemTemp.createTempSync('mentions_files');
      addTearDown(() => disk.deleteSync(recursive: true));
      for (final (path, text) in [
        ('app/lib/main.dart', 'main() {}'),
        ('app/build/out.txt', 'x'),
        ('app/.gitignore', 'build/\n'),
      ]) {
        File(p.joinAll([disk.path, ...path.split('/')]))
          ..createSync(recursive: true)
          ..writeAsStringSync(text);
      }
    });

    for (final environment in ['wsl-arch', 'ssh-box']) {
      test('a checkout in $environment is listed by the server, and its '
          '.gitignore is honoured', () async {
        server.filesWork.posixAt(environment, disk.path);
        db.server.sessionRows.insert(
          session(
            workingDirectory: EnvironmentPath(
              environmentId: environment,
              path: '/app',
            ),
          ),
        );
        final container = ProviderContainer(
          overrides: [
            await server.override(),
            ...fakeTerminalOverrides(machine: db),
          ],
        );
        addTearDown(container.dispose);

        final options = await container
            .read(sessionMentionsProvider('s1'))
            .options('main');
        expect(_inserts(options), contains('@lib/main.dart'));
        final all = _inserts(
          await container.read(sessionMentionsProvider('s1')).options(''),
        );
        expect(all.where((i) => i.contains('build')), isEmpty);
        expect(server.filesWork.kinds, contains('files.index'));
      });
    }
  });
}
