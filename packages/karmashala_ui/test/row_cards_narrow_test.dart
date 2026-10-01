import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// The session and project cards at every width a pane or a phone gives them,
/// at both densities and three text scales, with the longest facts they carry.
///
/// Measured before the fix: a labelled status badge beside an "active …" age
/// overflowed line one by 243px at 360@2.0; `+12949 −10310 ↑14` beside a
/// worktree overflowed line three at pointer 200 while selecting; a long SSH
/// environment badge overflowed a project's path line by up to 816px.
void main() {
  const widths = [200.0, 240.0, 320.0, 360.0];

  /// What the companion passes as a badge: a glyph and a word, not flexible.
  Widget labelledBadge() => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(AppIcons.circle, size: 13),
      SizedBox(width: 4),
      Text('Waiting for input', maxLines: 1),
    ],
  );

  /// Each density with the verbs its surface really passes: the Explorer has a
  /// menu, a pin and a `+`; the phone has none of them.
  Widget session(UiDensity density, {required bool selecting}) => SessionCard(
    depth: 1,
    selected: true,
    agentIcon: AppIcons.robot,
    agentLabel: 'Claude Code  ·  running in an external terminal',
    agentColor: Colors.teal,
    badge: labelledBadge(),
    age: 'active 7h 59m ago',
    ageTooltip: 'Last written',
    title: 'Benchmark every arcade game against the reference renderer',
    branch: 'feature/a-rather-long-branch-name-for-the-benchmarks',
    subPath: 'packages/karmashala_ui',
    whereabouts: 'opened in an external terminal',
    stat: const SessionDiffStat(added: 12949, removed: 10310, commitsAhead: 14),
    worktree: true,
    pinned: true,
    link: SessionLink.fork,
    parentTitle: 'Parent session',
    showMenu: !density.isTouch,
    selecting: selecting,
    ticked: selecting,
    onTap: () {},
    menuItemsBuilder: () => const [],
    onMenu: (_) {},
  );

  Widget project(UiDensity density, {required bool missing}) => ProjectCard(
    name: 'popupbits-ai-workspace-with-a-very-long-project-name',
    path: '/home/someone/src/popupbits/projects/karmashala-app/karmashala-app',
    expanded: true,
    selected: false,
    missing: missing,
    pinned: true,
    onTogglePin: density.isTouch ? null : () {},
    onNewSession: density.isTouch ? null : () {},
    showMenu: !density.isTouch,
    environmentBadge: 'SSH: build-server-eu-west-1.internal.example.com',
    summary: const ProjectSummary(
      sessions: 34,
      changedFiles: 120,
      running: 12,
      needsAttention: 3,
    ),
    onTap: () {},
    menuItemsBuilder: () => const [],
    onMenu: (_) {},
  );

  Future<void> sweep(
    WidgetTester tester,
    Map<String, Widget Function(UiDensity density)> cases,
  ) async {
    final findings = <String>[];
    for (final density in UiDensity.values) {
      for (final width in widths) {
        for (final scale in sweepScales) {
          for (final entry in cases.entries) {
            final overflows = await pumpInBox(
              tester,
              width: width,
              density: density,
              textScale: scale,
              child: SingleChildScrollView(child: entry.value(density)),
            );
            for (final overflow in overflows) {
              findings.add(
                '${entry.key} ${density.name} ${width.toInt()}@${scale}x: '
                '$overflow',
              );
            }
          }
        }
      }
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  }

  testWidgets('a session card never overflows', (tester) async {
    await sweep(tester, {
      'session': (density) => session(density, selecting: false),
      'session (selecting)': (density) => session(density, selecting: true),
    });
  });

  testWidgets('a project card never overflows', (tester) async {
    await sweep(tester, {
      'project': (density) => project(density, missing: false),
      'project (missing)': (density) => project(density, missing: true),
    });
  });

  testWidgets('the age and the badge keep their room when they fit', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 360,
      // The three-line card is the touch one: under a pointer a session is
      // one line, its branch and diff stat in the title's hover.
      density: UiDensity.touch,
      child: SessionCard(
        depth: 0,
        selected: false,
        agentIcon: AppIcons.robot,
        agentLabel: 'Claude Code',
        badge: labelledBadge(),
        age: '22m',
        title: 'Title',
        branch: 'main',
        stat: const SessionDiffStat(added: 9, removed: 1),
        onTap: () {},
        menuItemsBuilder: () => const [],
        onMenu: (_) {},
      ),
    );
    for (final text in ['22m', 'Waiting for input', '+9', '−1']) {
      final painted = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.text(text), matching: find.byType(RichText)),
      );
      expect(painted.didExceedMaxLines, isFalse, reason: text);
      expect(
        tester.getSize(find.text(text)).width,
        moreOrLessEquals(painted.getMaxIntrinsicWidth(double.infinity)),
        reason: '"$text" is drawn whole, not squeezed',
      );
    }
  });

  testWidgets('the environment badge keeps its name when there is room', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 600,
      density: UiDensity.touch,
      child: ProjectCard(
        name: 'app',
        path: '/w/app',
        expanded: false,
        selected: false,
        environmentBadge: 'WSL: Ubuntu',
        summary: const ProjectSummary(sessions: 1),
        onTap: () {},
        menuItemsBuilder: () => const [],
        onMenu: (_) {},
      ),
    );
    final painted = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('WSL: Ubuntu'),
        matching: find.byType(RichText),
      ),
    );
    expect(painted.didExceedMaxLines, isFalse);
    expect(find.text('/w/app'), findsOneWidget);
  });
}
