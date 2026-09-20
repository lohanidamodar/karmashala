import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_mcp/instructions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';

/// The skills, held against the two things they claim: that they list the
/// topics the `instructions` tool actually serves, and that every tool they
/// name is one this app serves.
///
/// Both are anti-drift assertions of the kind `mcp_tool_catalogue_test` makes,
/// and for a sharper reason. A guide that goes stale is read by an agent that
/// called for it. A **skill** is discovered by the CLI without being asked
/// for, so a tool name that stopped existing reads as a capability this app
/// has — to every session on the machine, until someone notices.
void main() {
  final servedNames = <String>{
    for (final schema in LauncherControlServer.toolSchemas)
      schema['name']! as String,
  };

  /// Every tool name a body mentions.
  ///
  /// Snake_case with at least one underscore, which is the shape of every tool
  /// this app serves and of nothing else in these bodies — `cli`,
  /// `projectId` and `agentInstallationId` are deliberately not caught.
  Set<String> toolNamesIn(String text) => <String>{
    for (final match in RegExp(
      r'\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b',
    ).allMatches(text))
      match.group(0)!,
  };

  test('the instructions skill lists exactly the tool\'s topics', () {
    final skill = kKarmashalaSkills.singleWhere(
      (s) => s.name == 'karmashala-instructions',
    );
    final topics = <String>[
      for (final line in skill.body.split('\n'))
        if (RegExp(r'^  [a-z][a-z0-9-]* — ').hasMatch(line))
          line.trim().split(' — ').first,
    ];
    expect(topics, <String>[for (final guide in kMcpGuides) guide.topic]);
    // And the summaries, so a reworded guide cannot leave the skill describing
    // the old one.
    for (final guide in kMcpGuides) {
      expect(skill.body, contains('  ${guide.topic} — ${guide.summary}'));
    }
  });

  test('every tool a skill names is a served tool', () {
    for (final skill in kKarmashalaSkills) {
      final named = toolNamesIn(skill.render());
      expect(
        named.difference(servedNames),
        isEmpty,
        reason:
            '${skill.name} names these, and this app serves no such tool. '
            'A skill is read without being asked for, so a stale name is a '
            'capability claim on every session on the machine.',
      );
      expect(named, isNotEmpty, reason: '${skill.name} names no tool at all');
    }
  });

  test('the skills the backlog names are the skills that ship', () {
    expect(kKarmashalaSkills.map((s) => s.name), <String>[
      'karmashala-instructions',
      'karmashala-advisor',
      'karmashala-committee',
    ]);
  });

  test('every skill is discoverable and installable', () {
    for (final skill in kKarmashalaSkills) {
      // Lowercase and hyphenated: a directory name on Windows, and what
      // Antigravity's own skills guide asks for.
      expect(skill.name, matches(RegExp(r'^karmashala-[a-z][a-z0-9-]*$')));
      // The description is what a CLI reads to decide whether to open the
      // skill, so an empty or wordless one is a skill nobody finds.
      expect(skill.description.split(' ').length, greaterThan(10));
      expect(skill.description, contains('Use '));
      expect(skill.body.trim(), startsWith('# '));
    }
  });

  test('each skill says what a stopped Karmashala means, or names no tool '
      'that needs one', () {
    // The one cost of leaving constant bytes behind when the app quits: a
    // skill that names tools nothing is serving. It is answered in the text
    // rather than by deleting and rewriting the file every launch.
    final instructions = kKarmashalaSkills.first;
    expect(
      instructions.body.replaceAll(RegExp(r'\s+'), ' '),
      contains('Karmashala is not connected to this session'),
    );
  });

  test('the rendered skill carries the marker uninstall matches on', () {
    for (final skill in kKarmashalaSkills) {
      expect(skill.render(), contains('<!-- karmashala-skill'));
    }
  });
}
