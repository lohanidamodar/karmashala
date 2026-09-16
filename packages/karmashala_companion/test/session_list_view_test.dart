import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/src/presentation/session_list_view.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_test_support.dart';

/// Which of its four shapes the Projects tab takes, decided without widgets.
void main() {
  List<CompanionSessionSummary> twoMachines() => [
    summary(
      's1',
      project: 'popupbits',
      projectId: 'p1',
      environmentId: 'windows',
      environmentBadge: 'Windows',
    ),
    summary(
      's2',
      project: 'content',
      projectId: 'p2',
      status: CompanionSessionStatus.idle,
      environmentId: 'windows',
      environmentBadge: 'Windows',
    ),
    summary(
      's3',
      project: 'droplet',
      projectId: 'p3',
      environmentId: 'ssh:h1',
      environmentBadge: 'do-box',
    ),
  ];

  test('several machines and none chosen asks which machine first', () {
    final view = sessionListViewOf(
      sessions: twoMachines(),
      projects: null,
      chosenEnvironment: null,
      rawQuery: '',
    );
    expect(view, isA<EnvironmentPick>());
    expect(
      (view as EnvironmentPick).environments.map((e) => e.label),
      containsAll(['Windows', 'do-box']),
    );
  });

  test('a search crosses every machine instead of asking', () {
    final view = sessionListViewOf(
      sessions: twoMachines(),
      projects: null,
      chosenEnvironment: null,
      rawQuery: '  CONTENT ',
    );
    expect(view, isA<ProjectIndex>());
    expect((view as ProjectIndex).groups.map((g) => g.name), ['content']);
  });

  test('a chosen machine scopes the index and remembers the way back', () {
    final view = sessionListViewOf(
      sessions: twoMachines(),
      projects: null,
      chosenEnvironment: 'windows',
      rawQuery: '',
    );
    expect(view, isA<ProjectIndex>());
    final index = view as ProjectIndex;
    expect(index.groups.map((g) => g.name), ['popupbits', 'content']);
    expect(index.running.map((s) => s.id), ['s1']);
    expect(index.machine?.label, 'Windows');
  });

  test('a machine that is gone reads as all of them', () {
    final view = sessionListViewOf(
      sessions: [summary('s1', project: 'a', projectId: 'p1')],
      projects: null,
      chosenEnvironment: 'ssh:gone',
      rawQuery: '',
    );
    expect(view, isA<SingleProject>());
    expect((view as SingleProject).machine, isNull);
  });

  test('one project lifts its running sessions above the rest', () {
    final view = sessionListViewOf(
      sessions: [
        summary('s1', project: 'a', projectId: 'p1'),
        summary(
          's2',
          project: 'a',
          projectId: 'p1',
          status: CompanionSessionStatus.idle,
        ),
      ],
      projects: null,
      chosenEnvironment: null,
      rawQuery: '',
    );
    final single = view as SingleProject;
    expect(single.group.name, 'a');
    expect(single.running.map((s) => s.id), ['s1']);
    expect(single.rest.map((s) => s.id), ['s2']);
  });

  test('a search that matches nothing says so', () {
    expect(
      sessionListViewOf(
        sessions: [summary('s1', project: 'a', projectId: 'p1')],
        projects: null,
        chosenEnvironment: null,
        rawQuery: 'zzz-nothing',
      ),
      isA<NoMatch>(),
    );
    expect(
      sessionListViewOf(
        sessions: [
          summary('s1', project: 'a', projectId: 'p1'),
          summary('s2', project: 'b', projectId: 'p2'),
        ],
        projects: null,
        chosenEnvironment: null,
        rawQuery: 'zzz-nothing',
      ),
      isA<NoMatch>(),
    );
  });
}
