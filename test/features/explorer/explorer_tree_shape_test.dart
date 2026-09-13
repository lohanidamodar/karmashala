import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_nodes.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';

import '../../support/fixtures.dart';

/// **The Explorer's shape, asserted without a widget.**
///
/// The tree used to be built straight into a `ListView`'s children, so the only
/// way to ask what it drew was to pump it and read the rendered rows — which
/// answers about a screenful, not about the tree. As a flat list of values the
/// whole sequence is one expectation, and the rules that are easy to break by
/// accident (a collapsed machine still paying for its projects, a context drawn
/// where it holds nothing) are each one line.
Workspace context(String id, String name) =>
    Workspace(id: id, name: name, createdAt: testTime);

/// `env:windows > Projects > proc-nepal` as a readable line per row.
List<String> sketch(List<ExplorerNode> nodes) => [
  for (final node in nodes)
    '${'  ' * node.depth}${switch (node) {
      EnvironmentNode(:final label, :final expanded) =>
        '${expanded ? '-' : '+'} $label',
      EnvironmentSectionNode(:final label, :final expanded, :final count) =>
        '${expanded ? '-' : '+'} $label${count == null ? '' : ' ($count)'}',
      ContextNode(:final label, :final expanded, :final projectCount) =>
        '${expanded ? '-' : '+'} $label [$projectCount]',
      ProjectNode(:final project, :final expanded) =>
        '${expanded ? '-' : '+'} ${project.name}',
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
    project(id: 'p5', name: 'Test ssh', environmentId: 'ssh:h1'),
  ];

  List<ExplorerNode> tree({
    Set<String> collapsed = const {},
    Set<String> expandedProjects = const {},
  }) => buildExplorerTree(
    projects: projects,
    environments: environments,
    contexts: contexts,
    collapsed: collapsed,
    expandedProjects: expandedProjects,
  );

  test('machine, then its sections, then contexts before loose projects', () {
    expect(sketch(tree()), [
      '- Windows',
      '  - Projects (3)',
      '    - Client work [2]',
      '      + proc-nepal',
      '      + jholunge',
      '    + field-report',
      '  + Terminals',
      '- Ubuntu',
      '  - Projects (1)',
      '    + popupbits',
      '  + Terminals',
      '- build-box',
      '  - Projects (1)',
      '    + Test ssh',
      '  + Terminals',
    ]);
  });

  test('a collapsed machine costs nothing below it', () {
    final nodes = tree(collapsed: {'env:windows'});

    expect(
      nodes.whereType<ProjectNode>().any(
        (n) => n.project.root.environmentId == 'windows',
      ),
      isFalse,
      reason: 'a machine nobody opened must not put its projects in the list',
    );
    expect(sketch(nodes).first, '+ Windows');
  });

  test('a collapsed context keeps its own row and its count', () {
    final nodes = tree(collapsed: {'env:windows/ctx:c1'});

    expect(sketch(nodes).take(4), [
      '- Windows',
      '  - Projects (3)',
      '    + Client work [2]',
      '    + field-report',
    ]);
  });

  test('Terminals dials nothing until it is expanded, and never at launch', () {
    final asked = <String>[];
    List<ExplorerNode> record(EnvironmentNode node) {
      asked.add(node.environmentId);
      return const [];
    }

    buildExplorerTree(
      projects: projects,
      environments: environments,
      contexts: contexts,
      collapsed: const {},
      expandedProjects: const {},
      terminalsOf: record,
    );
    expect(
      asked,
      isEmpty,
      reason: 'expansion is not persisted, so a fresh launch dials nobody',
    );

    buildExplorerTree(
      projects: projects,
      environments: environments,
      contexts: contexts,
      collapsed: const {},
      expandedProjects: const {},
      expandedTerminals: const {'ssh:h1'},
      terminalsOf: record,
    );
    expect(asked, ['ssh:h1'], reason: 'only the machine the user opened');
  });

  test('an unasked Terminals count is null, never a zero', () {
    final terminals = tree().whereType<EnvironmentSectionNode>().where(
      (n) => n.section == EnvironmentSection.terminals,
    );

    expect(terminals, isNotEmpty);
    expect(
      terminals.every((n) => n.count == null),
      isTrue,
      reason: 'nobody has looked, and a zero would say the machine is idle',
    );
  });

  test('a context nobody filed anything under is not drawn', () {
    expect(
      tree().whereType<ContextNode>().map((n) => n.label),
      ['Client work'],
      reason: '"Personal" holds no project, so no machine has a row for it',
    );
  });

  test('a context spanning two machines is drawn under each', () {
    final nodes = buildExplorerTree(
      projects: [
        project(id: 'p1', name: 'here', workspaceId: 'c1'),
        project(
          id: 'p2',
          name: 'there',
          environmentId: 'wsl:Ubuntu',
          workspaceId: 'c1',
        ),
      ],
      environments: environments,
      contexts: contexts,
      collapsed: const {},
      expandedProjects: const {},
    );

    expect(
      nodes.whereType<ContextNode>().map((n) => n.environmentId),
      ['windows', 'wsl:Ubuntu'],
      reason: 'the context really is on both machines; one row would hide that',
    );
  });

  test('a project naming an environment the workspace lost keeps its own group', () {
    final nodes = buildExplorerTree(
      projects: [project(id: 'p1', name: 'orphan', environmentId: 'ssh:gone')],
      environments: environments,
      contexts: const [],
      collapsed: const {},
      expandedProjects: const {},
    );
    final orphan = nodes.whereType<EnvironmentNode>().last;

    expect(orphan.environment, isNull);
    expect(
      orphan.label,
      'ssh:gone',
      reason: 'named by its id rather than folded into this machine',
    );
  });

  test('an empty machine is still drawn, and says so', () {
    final nodes = buildExplorerTree(
      projects: const [],
      environments: [windowsEnv()],
      contexts: const [],
      collapsed: const {},
      expandedProjects: const {},
    );

    expect(sketch(nodes), [
      '- Windows',
      '  - Projects (0)',
      '    # No projects on this machine yet.',
      '  + Terminals',
    ]);
  });

  test('only an expanded project is asked for its sessions', () {
    final asked = <String>[];
    buildExplorerTree(
      projects: projects,
      environments: environments,
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

  test('a project sits deeper inside a context than loose beside it', () {
    final byName = {
      for (final node in tree().whereType<ProjectNode>())
        node.project.name: node.depth,
    };

    expect(byName['proc-nepal'], 3);
    expect(byName['field-report'], 2);
  });
}
