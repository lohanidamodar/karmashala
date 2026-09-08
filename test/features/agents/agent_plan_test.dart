import 'dart:convert';

import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_plan.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// **What each CLI publishes as its own plan, pinned to a real transcript.**
///
/// The reason this file exists rather than a comment: Claude Code's transcript
/// format is internal and changes between versions (BACKLOG 52), and the
/// failure mode of a format change here is an *empty* plan drawn beside a
/// running agent — silent, and read as "no work planned". So every claim in
/// `agent_plan.dart` is asserted against the payload it was read off, and a
/// future version that renames a key fails here first.
///
/// The payloads below are verbatim from the owner's own stores, read
/// 2026-09-08; only the number of items is cut down.
void main() {
  /// Claude Code, `TodoWrite`: `message.content[].tool_use.input`.
  const claudeInput = {
    'todos': [
      {
        'content': 'Audit existing template systems',
        'activeForm': 'Auditing existing template systems',
        'status': 'in_progress',
      },
      {
        'content': 'Create folder structure under data/, scenes/, scripts/',
        'activeForm': 'Creating folder structure',
        'status': 'pending',
      },
      {
        'content': 'Document font/Devanagari handling',
        'activeForm': 'Documenting font/Devanagari handling',
        'status': 'completed',
      },
    ],
  };

  /// Codex, `update_plan`: `payload.arguments`, which is a JSON **string**.
  final codexArguments = jsonEncode({
    'explanation':
        'Calibrate the Nepali patro Surya Siddhanta defaults against the '
        'user-provided 2081 Baisakh reference.',
    'plan': [
      {
        'step': 'Inspect current Nepali patro SS config',
        'status': 'completed',
      },
      {
        'step': 'Measure current Baisakh 2081 outputs against the reference',
        'status': 'in_progress',
      },
      {'step': 'Adjust defaults and add focused coverage', 'status': 'pending'},
    ],
  });

  group('Claude Code writes a TodoWrite snapshot', () {
    test('the declared shape reads a real call', () {
      final plan = kClaudeCodeTodoWrite.planIn(claudeInput);
      expect(plan, isNotNull);
      expect(plan!.total, 3);
      expect(plan.doneCount, 1);
      expect(plan.current?.text, 'Audit existing template systems');
      // `TodoWrite` carries no sentence about the plan as a whole.
      expect(plan.note, isEmpty);
      expect(plan.items.map((i) => i.state), [
        AgentPlanItemState.inProgress,
        AgentPlanItemState.pending,
        AgentPlanItemState.completed,
      ]);
    });

    test('the tool name and the three state words are the ones measured', () {
      expect(kClaudeCodeTodoWrite.toolName, 'TodoWrite');
      expect(kClaudeCodeTodoWrite.itemsKey, 'todos');
      expect(kClaudeCodeTodoWrite.textKey, 'content');
      expect(kClaudeCodeTodoWrite.stateWords.keys, [
        'pending',
        'in_progress',
        'completed',
      ]);
      expect(kClaudeCodeTodoWrite.style, AgentPlanStyle.snapshot);
    });

    test('activeForm is not read as a second item', () {
      // The same line in the present participle is the CLI's spinner text, not
      // another fact about the work.
      final plan = kClaudeCodeTodoWrite.planIn(claudeInput)!;
      expect(
        plan.items.map((i) => i.text),
        isNot(contains('Auditing existing template systems')),
      );
    });
  });

  group('Codex writes an update_plan snapshot', () {
    test('the declared shape reads a real call, arguments-as-string', () {
      final plan = kCodexUpdatePlan.planIn(codexArguments);
      expect(plan, isNotNull);
      expect(plan!.total, 3);
      expect(plan.doneCount, 1);
      expect(
        plan.current?.text,
        'Measure current Baisakh 2081 outputs against the reference',
      );
      expect(plan.note, startsWith('Calibrate the Nepali patro'));
    });

    test('its vocabulary is not Claude Code\'s', () {
      // Measured, not assumed: the state *words* are identical and the two
      // keys that matter are not. Reading Codex with Claude's declaration
      // yields nothing at all, which is what this pins.
      expect(kCodexUpdatePlan.itemsKey, 'plan');
      expect(kCodexUpdatePlan.textKey, 'step');
      expect(kClaudeCodeTodoWrite.planIn(codexArguments), isNull);
      expect(kCodexUpdatePlan.planIn(claudeInput), isNull);
    });
  });

  group('Antigravity publishes no plan', () {
    test('the descriptor says so, with words for the panel', () {
      final descriptor = AgentRegistry.builtIn.byId(AgentIds.antigravity)!;
      expect(descriptor.plan.isSupported, isFalse);
      expect(descriptor.plan.style, AgentPlanStyle.none);
      expect(descriptor.plan.refusal, isNotEmpty);
      // Nothing to have verified, so nothing is claimed to have been.
      expect(descriptor.plan.evidence, isEmpty);
    });

    test('an unsupported agent reads no plan out of anything', () {
      final none = AgentRegistry.builtIn.byId(AgentIds.antigravity)!.plan;
      expect(none.planIn(claudeInput), isNull);
      expect(none.planIn(codexArguments), isNull);
    });
  });

  group('every declared axis carries its evidence', () {
    test('the two agents that publish a plan name where it was read', () {
      for (final id in [AgentIds.claudeCode, AgentIds.codex]) {
        final support = AgentRegistry.builtIn.byId(id)!.plan;
        expect(support.isSupported, isTrue, reason: id);
        expect(support.evidence, isNotEmpty, reason: id);
        expect(
          support.evidence,
          contains('2026-09-08'),
          reason: '$id: the evidence must say when it was read',
        );
      }
    });

    test('the registry and the by-name lookup cannot disagree', () {
      for (final descriptor in AgentRegistry.builtIn.descriptors) {
        if (!descriptor.plan.isSupported) continue;
        expect(
          agentPlanToolsByName[descriptor.plan.toolName],
          same(descriptor.plan),
          reason:
              '${descriptor.id} declares ${descriptor.plan.toolName} but the '
              'transcript reader looks up something else',
        );
      }
    });
  });

  group('a shape we no longer understand yields nothing new', () {
    test('a renamed items key reads as null, never as an empty plan', () {
      expect(kClaudeCodeTodoWrite.planIn({'items': <Object>[]}), isNull);
      expect(kClaudeCodeTodoWrite.planIn({'todos': 'not a list'}), isNull);
      expect(kClaudeCodeTodoWrite.planIn(null), isNull);
      expect(kClaudeCodeTodoWrite.planIn('{not json'), isNull);
    });

    test('an empty list reads as null too, and that is a decision', () {
      // It cannot be told apart from a shape we misread, and no agent in 265
      // measured calls has ever written one.
      expect(kClaudeCodeTodoWrite.planIn({'todos': <Object>[]}), isNull);
    });

    test('a renamed state word leaves the item, marked unrecorded', () {
      // The opposite direction from the key above: the list is plainly still a
      // list, so dropping it would lose real work — but a word we do not know
      // must not be counted as done.
      final plan = kClaudeCodeTodoWrite.planIn({
        'todos': [
          {'content': 'Ship it', 'status': 'blocked'},
        ],
      });
      expect(plan!.items.single.state, AgentPlanItemState.unrecorded);
      expect(plan.doneCount, 0);
      expect(plan.isFinished, isFalse);
    });

    test('an item with no text is skipped, not shown blank', () {
      final plan = kClaudeCodeTodoWrite.planIn({
        'todos': [
          {'content': '   ', 'status': 'pending'},
          {'content': 'Real work', 'status': 'pending'},
        ],
      });
      expect(plan!.total, 1);
      expect(plan.items.single.text, 'Real work');
    });
  });

  group('a plan says whether it is finished', () {
    AgentPlan planOf(List<String> states) => kClaudeCodeTodoWrite.planIn({
      'todos': [
        for (var i = 0; i < states.length; i++)
          {'content': 'step $i', 'status': states[i]},
      ],
    })!;

    test('all completed is finished; anything left is not', () {
      expect(planOf(['completed', 'completed']).isFinished, isTrue);
      expect(planOf(['completed', 'pending']).isFinished, isFalse);
      expect(planOf(['in_progress']).isFinished, isFalse);
    });

    test('the headline names what it is on, bounded', () {
      expect(planOf(['completed', 'in_progress']).headline, contains('1/2'));
      expect(planOf(['completed', 'in_progress']).headline, contains('step 1'));
      expect(planOf(['completed']).headline, '1/1 done');
      final long = kClaudeCodeTodoWrite.planIn({
        'todos': [
          {'content': 'x' * 400, 'status': 'in_progress'},
        ],
      })!;
      expect(long.headline.length, lessThan(120));
      expect(long.headline, endsWith('…'));
    });

    test('two plans with the same items are the same value', () {
      // The panel must not rebuild because the file moved and said the same
      // thing.
      expect(planOf(['pending']), planOf(['pending']));
      expect(planOf(['pending']).hashCode, planOf(['pending']).hashCode);
      expect(planOf(['pending']), isNot(planOf(['completed'])));
    });
  });

  group('the by-name seam', () {
    test('answers for both tools and nothing else', () {
      expect(agentPlanForToolCall('TodoWrite', claudeInput), isNotNull);
      expect(agentPlanForToolCall('update_plan', codexArguments), isNotNull);
      expect(agentPlanForToolCall('Bash', {'command': 'ls'}), isNull);
      // Antigravity's own `manage_task` is a *background shell command*, not a
      // plan — see `agent_plan.dart` and the report that measured it.
      expect(
        agentPlanForToolCall('manage_task', {
          'Action': 'status',
          'TaskId': 'x/task-14',
        }),
        isNull,
      );
    });
  });
}
