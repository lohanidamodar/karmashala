import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_nodes.dart';
import 'package:karmashala/src/features/explorer/application/where_you_are.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';

import '../../support/fixtures.dart';

/// **Where the sidebar thinks you are.**
///
/// Three readings of decreasing liveness, and the order between them is the
/// whole rule: an agent pane paints a TUI and emits no OSC 7, so its hook is
/// the only live answer; a shell reports its own `cd`; and what a session
/// recorded is where it *started*, which may be nowhere near where it is.
EnvironmentPath at(String path, {String environmentId = 'windows'}) =>
    EnvironmentPath(environmentId: environmentId, path: path);

void main() {
  group('which reading wins', () {
    test("an agent's hook outranks the pane it paints into", () {
      expect(
        whereYouAre(
          agentReported: at(r'C:\src\app\packages\core'),
          paneReported: at(r'C:\src\app'),
          recorded: at(r'C:\src\app'),
        )?.path,
        r'C:\src\app\packages\core',
        reason:
            'an agent pane never emits OSC 7, so the pane is stale by '
            'construction the moment the agent moves',
      );
    });

    test("a shell's own cd outranks where its session was launched", () {
      expect(
        whereYouAre(
          paneReported: at(r'C:\src\other'),
          recorded: at(r'C:\src\app'),
        )?.path,
        r'C:\src\other',
      );
    });

    test('what was recorded is the answer when nothing else spoke', () {
      expect(whereYouAre(recorded: at(r'C:\src\app'))?.path, r'C:\src\app');
    });

    test('nothing answered is null, never a guess', () {
      expect(whereYouAre(), isNull);
    });
  });

  group('the ancestors a reveal has to open', () {
    test('a loose project needs the No context header open', () {
      expect(explorerAncestorsOf(), ['ctx:none']);
    });

    test('a filed project needs its context open', () {
      expect(explorerAncestorsOf(workspaceId: 'c1'), ['ctx:c1']);
    });

    test('the ids are the ones the tree itself builds', () {
      // The reveal and the tree must spell these the same way or the row stays
      // hidden — which is why one function builds them.
      final filed = project(id: 'p1', workspaceId: 'c1');
      final loose = project(id: 'p2');
      final nodes = buildExplorerTree(
        projects: [filed, loose],
        environments: environmentChoices([filed, loose], [windowsEnv()]),
        contexts: [Workspace(id: 'c1', name: 'Client', createdAt: testTime)],
        collapsed: const {},
        expandedProjects: const {},
      );
      expect(nodes.whereType<ContextHeaderNode>().map((node) => node.id), [
        ...explorerAncestorsOf(workspaceId: 'c1'),
        ...explorerAncestorsOf(),
      ]);
    });
  });
}
