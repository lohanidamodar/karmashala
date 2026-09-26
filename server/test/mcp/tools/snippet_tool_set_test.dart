import 'package:karmashala_host/src/mcp/tools/snippet_tool_set.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_snippets/store.dart';
import 'package:test/test.dart';

import 'tool_harness.dart';

/// `snippets_list` and `snippet_add`, run by the server (slice 2b): the
/// commands the user keeps. `snippet_insert` types into a pane and is the
/// app's; its tests are the app's.
void main() {
  late ToolHarness h;
  late SnippetToolSet tools;

  setUp(() {
    h = ToolHarness();
    tools = SnippetToolSet(h.context);
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
  ]) => h.map(tools, tool, arguments);

  List<Map<String, Object?>> snippetsOf(Map<String, Object?> answer) =>
      (answer['snippets']! as List).cast<Map<String, Object?>>();

  group('snippets_list', () {
    test('reports every snippet, and which fit the pane in front', () async {
      final asked = <String?>[];
      final withPane = SnippetToolSet(
        h.context,
        pane: (paneId) {
          asked.add(paneId);
          return const SnippetPane(
            paneId: 'pane-1',
            title: 'PowerShell',
            shellId: 'powerShell',
            isAgentPane: false,
            live: true,
          );
        },
      );
      await call('snippet_add', {
        'command': 'flutter test',
        'label': 'Run the tests',
      });
      await call('snippet_add', {
        'command': 'tail -f log',
        'label': 'Tail the log',
        'shell': 'wsl',
      });

      final answer = await h.map(withPane, 'snippets_list', {'paneId': ''});
      expect(asked, [null], reason: 'an empty paneId is the pane in front');
      expect(
        {for (final s in snippetsOf(answer)) s['label']: s['fitsPane']},
        {'Run the tests': true, 'Tail the log': false},
        reason:
            'a WSL snippet is listed in a PowerShell pane with fitsPane=false '
            '— hiding it would look like it was never saved',
      );
      expect(answer['pane'], {
        'paneId': 'pane-1',
        'title': 'PowerShell',
        'shell': 'powerShell',
        'isAgentPane': false,
        'live': true,
      });
    });

    test('answers with no pane at all rather than refusing', () async {
      await call('snippet_add', {'command': 'flutter test'});

      final answer = await call('snippets_list', {'paneId': 'pane-9'});

      expect(answer['pane'], isNull);
      expect(
        snippetsOf(answer).single['fitsPane'],
        isNull,
        reason: 'null is "no pane to compare against", not "does not fit"',
      );
      expect(snippetsOf(answer).single['shell'], isNull);
    });
  });

  group('snippet_add', () {
    test('saves what the user will see in their own palette', () async {
      final added = await call('snippet_add', {
        'command': 'flutter test --exclude-tags=live-ssh',
        'label': 'Run the tests',
        'shell': 'powerShell',
      });

      final saved = CommandSnippetDao(h.db).list().single;
      expect(saved.id, added['id']);
      expect(saved.label, 'Run the tests');
      expect(saved.shellId, 'powerShell');
      expect(
        saved.submit,
        isFalse,
        reason: 'an agent has to ask for a self-running snippet explicitly',
      );
      expect(added, {
        'id': saved.id,
        'label': 'Run the tests',
        'command': 'flutter test --exclude-tags=live-ssh',
        'shell': 'powerShell',
        'submit': false,
      });
    });

    test('flattens a multi-line command instead of storing a submit, and is '
        'named by it without a label', () async {
      final added = await call('snippet_add', {
        'command': 'git add -A\ngit commit',
      });

      final saved = CommandSnippetDao(h.db).list().single;
      expect(saved.command, 'git add -A git commit');
      expect(saved.label, 'git add -A git commit');
      expect(added['label'], 'git add -A git commit');
    });

    test('an unknown shell is refused, never dropped', () async {
      await expectLater(
        call('snippet_add', {'command': 'ls', 'shell': 'fish'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains(
              'No shell "fish". Use one of powerShell, commandPrompt, wsl, '
              'posix, ssh, or omit it',
            ),
          ),
        ),
      );
      expect(
        CommandSnippetDao(h.db).list(),
        isEmpty,
        reason: 'a mis-tagged snippet is worse than no snippet',
      );
    });

    test('a blank command is refused', () async {
      await expectLater(
        call('snippet_add', {'command': '  '}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains('command is required and cannot be blank.'),
          ),
        ),
      );
    });
  });

  test('both are served and annotated; there is no delete', () {
    expect(
      [for (final s in tools.schemas) s['name']],
      ['snippets_list', 'snippet_add'],
    );
    expect(kMcpToolAnnotations['snippets_list']!.readOnly, isTrue);
    expect(kMcpToolAnnotations['snippet_add']!.idempotent, isFalse);
    expect(kMcpToolAnnotations.containsKey('snippet_delete'), isFalse);
  });
}
