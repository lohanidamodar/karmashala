import 'dart:convert';

import 'package:karmashala_mcp/catalogue.dart';
import 'package:test/test.dart';

/// Arguments that make every conditionally gated tool gated.
const _reaching = <String, dynamic>{
  'sessionId': 'other',
  'kill': true,
  'id': 'theirs',
};

void main() {
  group('the group table', () {
    test('every gated tool is in a group', () {
      for (final tool in kMcpToolAnnotations.keys) {
        if (mcpToolNeedsOperatorGrant(tool, _reaching, 'me')) {
          expect(kMcpToolGroups, contains(tool), reason: tool);
        }
      }
    });

    test('no tool in a group is unknown or outside the gate', () {
      for (final tool in kMcpToolGroups.keys) {
        expect(kMcpToolAnnotations, contains(tool), reason: tool);
        expect(
          mcpToolNeedsOperatorGrant(tool, _reaching, 'me'),
          isTrue,
          reason: tool,
        );
      }
    });

    test('each group lists its tools, and the defaults are the design', () {
      final all = [for (final g in McpToolGroup.values) ...g.tools];
      expect(all.toSet(), kMcpToolGroups.keys.toSet());
      expect(all, hasLength(kMcpToolGroups.length));
      expect(
        {
          for (final g in McpToolGroup.values)
            if (g.defaultOn) g,
        },
        {McpToolGroup.message, McpToolGroup.start},
      );
      expect(kMcpToolGroups['session_answer'], McpToolGroup.answer);
    });
  });

  group('the policy', () {
    test('round-trips through JSON and its stored form', () {
      final policy = McpToolAccessPolicy.defaults
          .withGlobal(
            McpToolAccessOverrides.none
                .withGroup(McpToolGroup.pipelines, true)
                .withTool('pipeline_run', false),
          )
          .withMessageAnyProject(true)
          .withProject(
            'p1',
            McpToolAccessOverrides.none.withGroup(McpToolGroup.message, false),
          );
      expect(McpToolAccessPolicy.fromJson(policy.toJson()), policy);
      expect(McpToolAccessPolicy.parse(jsonEncode(policy.toJson())), policy);
      expect(policy.toJson(), {
        'groups': {'pipelines': true},
        'tools': {'pipeline_run': false},
        'messageAnyProject': true,
        'projects': {
          'p1': {
            'groups': {'message': false},
          },
        },
      });
    });

    test('reads nothing it does not know, and nothing stored as defaults', () {
      expect(McpToolAccessPolicy.parse(null), McpToolAccessPolicy.defaults);
      expect(McpToolAccessPolicy.parse('{oops'), McpToolAccessPolicy.defaults);
      final odd = McpToolAccessPolicy.fromJson({
        'groups': {'nope': true, 'start': 'yes', 'answer': true},
        'tools': {'device_tap': true},
        'projects': {
          'p1': {'groups': {}},
        },
      });
      expect(odd.global.groups, {'answer': true});
      expect(odd.global.tools, isEmpty);
      expect(odd.projects, isEmpty);
    });

    test('clearing a project\'s last override drops the project', () {
      final on = McpToolAccessPolicy.defaults.withProject(
        'p1',
        McpToolAccessOverrides.none.withGroup(McpToolGroup.answer, true),
      );
      final off = on.withProject(
        'p1',
        on.project('p1').withGroup(McpToolGroup.answer, null),
      );
      expect(off, McpToolAccessPolicy.defaults);
    });
  });

  group('precedence', () {
    const tool = 'pipeline_run';
    final g = McpToolGroup.pipelines;

    test('the group default with nothing set', () {
      expect(McpToolAccessPolicy.defaults.toolOn(tool), isFalse);
      expect(McpToolAccessPolicy.defaults.toolOn('session_send'), isTrue);
      expect(McpToolAccessPolicy.defaults.toolOn('no_such_tool'), isFalse);
    });

    test('the global group switch beats the default', () {
      final p = McpToolAccessPolicy(
        global: McpToolAccessOverrides.none.withGroup(g, true),
      );
      expect(p.toolOn(tool), isTrue);
    });

    test('the global tool override beats the global group', () {
      final p = McpToolAccessPolicy(
        global: McpToolAccessOverrides.none
            .withGroup(g, true)
            .withTool(tool, false),
      );
      expect(p.toolOn(tool), isFalse);
      expect(p.toolOn('pipeline_approve'), isTrue);
    });

    test('the project group override beats the global tool', () {
      final p = McpToolAccessPolicy(
        global: McpToolAccessOverrides.none.withTool(tool, false),
        projects: {'p1': McpToolAccessOverrides.none.withGroup(g, true)},
      );
      expect(p.toolOn(tool, projectId: 'p1'), isTrue);
      expect(p.toolOn(tool, projectId: 'p2'), isFalse);
      expect(p.toolOn(tool), isFalse);
    });

    test('the project tool override beats everything', () {
      final p = McpToolAccessPolicy(
        projects: {
          'p1': McpToolAccessOverrides.none
              .withGroup(g, true)
              .withTool(tool, false),
        },
      );
      expect(p.toolOn(tool, projectId: 'p1'), isFalse);
      expect(p.toolOn('pipeline_approve', projectId: 'p1'), isTrue);
    });

    test('groupsOpen names the groups with a tool on', () {
      final p = McpToolAccessPolicy(
        global: McpToolAccessOverrides.none.withTool('worktree_remove', true),
      );
      expect(p.groupsOpen(), [
        McpToolGroup.message,
        McpToolGroup.start,
        McpToolGroup.pipelines,
      ]);
    });
  });

  group('the decision', () {
    // me and sib in p1; kid is me's child in p2; mum is me's parent in p3;
    // far is in p9; loose has no project.
    const projects = {
      'me': 'p1',
      'sib': 'p1',
      'kid': 'p2',
      'mum': 'p3',
      'far': 'p9',
    };
    const parents = {'me': 'mum', 'kid': 'me'};

    String? decide(
      String tool,
      Map<String, dynamic> args, {
      String caller = 'me',
      McpToolAccessPolicy policy = McpToolAccessPolicy.defaults,
    }) => mcpToolAccessRefusal(
      tool,
      args,
      caller,
      policy: policy,
      projectOf: (id) => projects[id],
      parentOf: (id) => parents[id],
    );

    test('a message reaches its own project, its parent and its child', () {
      for (final target in const ['me', 'sib', 'kid', 'mum']) {
        expect(
          decide('session_send', {'sessionId': target}),
          isNull,
          reason: target,
        );
      }
      expect(decide('session_send', const {}), isNull);
      expect(decide('session_rename', {'sessionId': 'sib'}), isNull);
    });

    test('another project is refused, with the way in', () {
      final refusal = decide('session_send', {'sessionId': 'far'});
      expect(refusal, isNotNull);
      expect(refusal, contains('NOTHING WAS DONE'));
      expect(refusal, contains('far'));
      expect(refusal, contains('Any project'));
      expect(refusal, contains(kMcpToolAccessLocation));
      expect(refusal, contains('Operate Karmashala'));
      expect(decide('session_draft', {'sessionId': 7}), isNotNull);
    });

    test('Any project lets it reach another project', () {
      expect(
        decide('session_send', {
          'sessionId': 'far',
        }, policy: McpToolAccessPolicy.defaults.withMessageAnyProject(true)),
        isNull,
      );
    });

    test('a session in no project reaches only its parent and children', () {
      const free = {'loose': null};
      String? fromLoose(String target) => mcpToolAccessRefusal(
        'session_send',
        {'sessionId': target},
        'loose',
        policy: McpToolAccessPolicy.defaults,
        projectOf: (id) => free.containsKey(id) ? null : projects[id],
        parentOf: (id) => id == 'sib' ? 'loose' : null,
      );
      expect(fromLoose('sib'), isNull);
      expect(fromLoose('far'), isNotNull);
    });

    test('a session in no project uses the global settings', () {
      final policy = McpToolAccessPolicy(
        global: McpToolAccessOverrides.none.withGroup(
          McpToolGroup.pipelines,
          true,
        ),
        projects: {
          'p1': McpToolAccessOverrides.none.withGroup(
            McpToolGroup.pipelines,
            false,
          ),
        },
      );
      expect(decide('pipeline_run', const {}, policy: policy), isNotNull);
      expect(
        decide('pipeline_run', const {}, caller: 'loose', policy: policy),
        isNull,
      );
    });

    test('an off group is refused, naming the tool and its group', () {
      final refusal = decide('session_answer', {'sessionId': 'sib'});
      expect(refusal, contains('session_answer'));
      expect(refusal, contains('"Answer approvals"'));
      expect(refusal, contains('NOTHING WAS DONE'));
      expect(refusal, contains(kMcpToolAccessLocation));
      expect(refusal, contains('for this project'));
      expect(refusal, contains('/operator'));
      expect(refusal, contains('only the person can'));
    });

    test('starting a session is on by default', () {
      expect(decide('open_new_session', const {}), isNull);
      expect(decide('subagent_run', const {}), isNull);
    });

    test('a tool in no group keeps the grant\'s own refusal', () {
      expect(decide('made_up', const {}), mcpOperatorRefusal('made_up'));
    });
  });
}
