import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_nodes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';

import '../../support/fixtures.dart';

/// **The Explorer's shape, asserted without a widget.**
///
/// As a flat list of values the whole sequence is one expectation, and the
/// rules that are easy to break by accident (a folded group still paying for
/// its projects, a header drawn where it holds nothing, a filter hiding the
/// project on screen) are each one line.
Workspace context(String id, String name) =>
    Workspace(id: id, name: name, createdAt: testTime);

/// One readable line per row: `= HEADER [count]`, then its rows by depth.
List<String> sketch(List<ExplorerNode> nodes) => [
  for (final node in nodes)
    '${'  ' * node.depth}${switch (node) {
      ContextHeaderNode(:final label, :final expanded, :final projectCount) => '${expanded ? '=' : '≠'} $label [$projectCount]',
      TerminalsHeaderNode(:final label, :final expanded, :final count) => '${expanded ? '=' : '≠'} $label${count == null ? '' : ' ($count)'}',
      SectionHeaderNode(:final section, :final expanded) => '${expanded ? '=' : '≠'} ${section.name}',
      ProjectNode(:final project, :final expanded, :final environmentLabel) => '${expanded ? '-' : '+'} ${project.name}'
          '${environmentLabel == null ? '' : ' @$environmentLabel'}',
      SessionRowNode(:final session) => '. ${session.title}',
      ImportedRowNode(:final session) => '~ ${session.id}',
      TerminalRowNode(:final terminal) => '> ${terminal.label}',
      HintNode(:final message) => '# $message',
    }}',
];

void main() {
  final environments = [windowsEnv(), wslEnv(), sshEnvFixture()];
  final contexts = [context('c1', 'Client work'), context('c2', 'Personal')];
  final projects = [
    project(id: 'p1', name: 'proc-nepal', workspaceId: 'c1'),
    project(id: 'p2', name: 'jholunge', workspaceId: 'c1'),
    project(id: 'p3', name: 'field-report'),
    project(id: 'p4', name: 'popupbits', environmentId: 'wsl:Ubuntu'),
    project(
      id: 'p5',
      name: 'Test ssh',
      environmentId: 'ssh:h1',
      workspaceId: 'c1',
    ),
  ];

  List<ExplorerNode> tree({
    List<Project>? of,
    List<Workspace>? within,
    Set<String> collapsed = const {},
    Set<String> expandedProjects = const {},
    String? environmentScope,
    WorkspaceScope contextScope = WorkspaceScope.all,
    String? keepProjectId,
    bool searching = false,
  }) => buildExplorerTree(
    projects: of ?? projects,
    environments: environmentChoices(projects, environments),
    contexts: within ?? contexts,
    collapsed: collapsed,
    expandedProjects: expandedProjects,
    environmentScope: environmentScope,
    contextScope: contextScope,
    keepProjectId: keepProjectId,
    searching: searching,
  );

  test('contexts by name, then the projects in none, then terminals', () {
    expect(sketch(tree()), [
      '= Client work [3]',
      '+ proc-nepal @Windows',
      '+ jholunge @Windows',
      '+ Test ssh @build-box',
      '= No context [2]',
      '+ field-report @Windows',
      '+ popupbits @Ubuntu',
      '≠ Windows · Terminals',
      '≠ Ubuntu · Terminals',
      '≠ build-box · Terminals',
    ]);
  });

  test(
    'two visible levels: every header and every project is at depth zero',
    () {
      final nodes = tree();

      expect(
        nodes.whereType<ExplorerHeaderNode>().map((n) => n.depth).toSet(),
        {0},
      );
      expect(nodes.whereType<ProjectNode>().map((n) => n.depth).toSet(), {0});
    },
  );

  test('with no contexts at all there are no context headers', () {
    expect(
      sketch(
        tree(
          of: [project(id: 'p1', name: 'alone')],
          within: const [],
          environmentScope: 'windows',
        ),
      ),
      ['+ alone', '≠ Terminals'],
      reason: 'a label over the whole list would tell nothing apart',
    );
  });

  test('a machine in scope is not repeated on its rows or its terminals', () {
    expect(sketch(tree(environmentScope: 'windows')), [
      '= Client work [2]',
      '+ proc-nepal',
      '+ jholunge',
      '= No context [1]',
      '+ field-report',
      '≠ Terminals',
    ]);
  });

  test('a context in scope lists that context and nothing beside it', () {
    expect(
      sketch(
        tree(contextScope: const WorkspaceScope.of('c1')),
      ).where((line) => !line.contains('Terminals')),
      [
        '= Client work [3]',
        '+ proc-nepal @Windows',
        '+ jholunge @Windows',
        '+ Test ssh @build-box',
      ],
    );
    expect(
      sketch(
        tree(contextScope: WorkspaceScope.unassigned),
      ).where((line) => !line.contains('Terminals')),
      ['= No context [2]', '+ field-report @Windows', '+ popupbits @Ubuntu'],
    );
  });

  test('a filter never hides the selected project, and says where it is', () {
    final nodes = tree(
      environmentScope: 'windows',
      contextScope: const WorkspaceScope.of('c1'),
      keepProjectId: 'p4',
    );

    expect(sketch(nodes).where((line) => !line.contains('Terminals')), [
      '= Client work [2]',
      '+ proc-nepal',
      '+ jholunge',
      '= No context [1]',
      '+ popupbits @Ubuntu',
    ], reason: 'kept under its own header, and named as another machine\'s');
  });

  test('a scope that holds nothing says so, in its own terms', () {
    expect(
      sketch(tree(contextScope: const WorkspaceScope.of('c2'))).first,
      '# No projects in Personal yet.',
    );
    expect(
      sketch(
        tree(
          environmentScope: 'ssh:h1',
          contextScope: WorkspaceScope.unassigned,
        ),
      ).first,
      '# Every project on build-box is in a context.',
    );
  });

  test('a collapsed context keeps its own row and its count, and no rows', () {
    final nodes = tree(collapsed: {contextHeaderId('c1')});

    expect(sketch(nodes).take(2), ['≠ Client work [3]', '= No context [2]']);
    expect(
      nodes.whereType<ProjectNode>().any((n) => n.project.workspaceId == 'c1'),
      isFalse,
      reason: 'a group nobody opened must not put its projects in the list',
    );
  });

  test('Terminals dials nothing until it is expanded, and never at launch', () {
    final asked = <String>[];
    List<ExplorerNode> record(TerminalsHeaderNode node) {
      asked.add(node.environmentId);
      return const [];
    }

    List<ExplorerNode> build(Set<String> expandedTerminals) =>
        buildExplorerTree(
          projects: projects,
          environments: environmentChoices(projects, environments),
          contexts: contexts,
          collapsed: const {},
          expandedProjects: const {},
          expandedTerminals: expandedTerminals,
          terminalsOf: record,
        );

    build(const {});
    expect(
      asked,
      isEmpty,
      reason: 'expansion is not persisted, so a fresh launch dials nobody',
    );

    build(const {'ssh:h1'});
    expect(asked, ['ssh:h1'], reason: 'only the machine the user opened');
  });

  test('an unasked Terminals count is null, never a zero', () {
    final terminals = tree().whereType<TerminalsHeaderNode>();

    expect(terminals, hasLength(3));
    expect(
      terminals.every((n) => n.count == null),
      isTrue,
      reason: 'nobody has looked, and a zero would say the machine is idle',
    );
  });

  test('a context nobody filed anything under is not drawn', () {
    expect(tree().whereType<ContextHeaderNode>().map((n) => n.label), [
      'Client work',
      'No context',
    ], reason: '"Personal" holds no project, so it has no header');
  });

  test('a context spanning two machines is one header, its rows named', () {
    final nodes = tree(
      of: [
        project(id: 'p1', name: 'here', workspaceId: 'c1'),
        project(
          id: 'p2',
          name: 'there',
          environmentId: 'wsl:Ubuntu',
          workspaceId: 'c1',
        ),
      ],
    );

    expect(sketch(nodes).take(3), [
      '= Client work [2]',
      '+ here @Windows',
      '+ there @Ubuntu',
    ]);
  });

  test('a project naming an environment the workspace lost is named by it', () {
    final orphan = project(id: 'p1', name: 'orphan', environmentId: 'ssh:gone');
    final choices = environmentChoices([orphan], environments);
    final nodes = buildExplorerTree(
      projects: [orphan],
      environments: choices,
      contexts: const [],
      collapsed: const {},
      expandedProjects: const {},
    );

    expect(choices.last.environment, isNull);
    expect(
      choices.last.label,
      'ssh:gone',
      reason: 'named by its id rather than folded into this machine',
    );
    expect(sketch(nodes).first, '+ orphan @ssh:gone');
    expect(sketch(nodes).last, '≠ ssh:gone · Terminals');
  });

  test('an empty machine is still listed, and still has its terminals', () {
    final choices = environmentChoices(const [], [windowsEnv()]);
    final nodes = buildExplorerTree(
      projects: const [],
      environments: choices,
      contexts: const [],
      collapsed: const {},
      expandedProjects: const {},
    );

    expect(choices.single.projectCount, 0);
    expect(sketch(nodes), ['# No projects yet.', '≠ Terminals']);
  });

  test('a search lists what matched under its header, and no terminals', () {
    expect(sketch(tree(of: [projects[1]], searching: true)), [
      '= Client work [1]',
      '+ jholunge @Windows',
    ]);
    expect(tree(of: const [], searching: true), isEmpty);
  });

  test('only an expanded project is asked for its sessions', () {
    final asked = <String>[];
    buildExplorerTree(
      projects: projects,
      environments: environmentChoices(projects, environments),
      contexts: contexts,
      collapsed: const {},
      expandedProjects: const {'p2'},
      childrenOf: (node) {
        asked.add(node.project.id);
        return const [];
      },
    );

    expect(asked, ['p2']);
  });

  test(
    'the scope is stored in a spelling no generated id can collide with',
    () {
      for (final scope in [
        WorkspaceScope.all,
        WorkspaceScope.unassigned,
        const WorkspaceScope.of('none'),
        const WorkspaceScope.of('c1'),
      ]) {
        expect(WorkspaceScope.parse(scope.stored), scope);
      }
      expect(WorkspaceScope.parse('nonsense'), WorkspaceScope.all);
    },
  );
}
