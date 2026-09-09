import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_options.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/settings/domain/permission_risk.dart';

/// The names borrowed from jean for our own rungs, and the three rules that
/// decide where they appear.
///
/// Nothing about the modes changed: every CLI still declares its own values,
/// with its own arguments and its own evidence, and this is a display rule over
/// the top of them. What it fixes is that the *rung* — the thing three CLIs
/// spell three ways — had no name a person could carry between them.
void main() {
  AgentPermissionSupport supportOf(String agentId) =>
      AgentRegistry.builtIn.byId(agentId)!.launch.permission;

  group('which rungs were borrowed', () {
    test('three of five, and the two that were not say why', () {
      expect(PermissionRisk.readOnly.familiarName, 'Plan');
      expect(PermissionRisk.acceptEdits.familiarName, 'Build');
      expect(PermissionRisk.autoRun.familiarName, 'Build');

      // jean has no equivalent of "ask": its approval flow is a separate axis
      // rather than a rung.
      expect(PermissionRisk.ask.familiarName, isNull);
      // Declined. "Bypass" says what is bypassed to somebody who has never met
      // the word; the dialog that guards it is titled with this label, and
      // "Yolo?" is a worse question to be asked before handing over a machine.
      expect(PermissionRisk.bypass.familiarName, isNull);
    });

    test('acceptEdits and autoRun share a name and stay distinguishable', () {
      // Both are Build in jean, and collapsing them would lose "still asks
      // before commands". The pairing keeps each CLI's own word beside it,
      // which is what carries the difference.
      final claude = supportOf(AgentIds.claudeCode);
      expect(
        describeSelectionFamiliar(
          claude,
          const PermissionSelection({'mode': 'acceptEdits'}),
        ),
        'Build · Accept edits',
      );
      expect(
        describeSelectionFamiliar(
          claude,
          const PermissionSelection({'mode': 'auto'}),
        ),
        'Build · Automatic',
      );
    });
  });

  group('where the borrowed name appears', () {
    test('not where the CLI already says the word', () {
      // Claude Code and Antigravity both label their read-only rung "Plan
      // mode". "Plan · Plan mode" is not clearer than "Plan mode", and the
      // names were borrowed only where they read better than ours.
      for (final agentId in [AgentIds.claudeCode, AgentIds.antigravity]) {
        expect(
          describeSelectionFamiliar(
            supportOf(agentId),
            const PermissionSelection({'mode': 'plan'}),
          ),
          'Plan mode',
          reason: agentId,
        );
      }
    });

    test('in front of the CLI own word where the CLI says something else', () {
      // Codex spells the same rung as a sandbox. This is the case the whole
      // change exists for: `read-only` stays, because a person configuring
      // Codex needs it, and "Plan" is what makes it the same rung as the other
      // two agents'.
      expect(
        describeSelectionFamiliar(
          supportOf(AgentIds.codex),
          const PermissionSelection({
            'sandbox': 'read-only',
            'approval': 'on-request',
          }),
        ),
        'Plan (Read-only · Codex decides when to ask)',
      );
    });

    test('bracketed when the CLI supplies more than one word', () {
      // One borrowed name, two CLI words: the brackets are how a reader tells
      // which came from where. Codex composes to acceptEdits, the least any
      // one axis permits.
      final codex = supportOf(AgentIds.codex);
      const selection = PermissionSelection({
        'sandbox': 'workspace-write',
        'approval': 'on-request',
      });
      expect(codex.riskOf(selection), PermissionRisk.acceptEdits);
      expect(
        describeSelectionFamiliarShort(codex, selection),
        'Build (Workspace · On request)',
      );
    });

    test('never over a rung nobody established', () {
      // `riskOf` answers null for an agent with no declared modes, and an
      // unknown is never a name.
      expect(pairedWithFamiliarName('Whatever it does', null),
          'Whatever it does');
    });

    test('never over the bypass rung, on any agent', () {
      for (final (agentId, selection) in [
        (AgentIds.claudeCode, const PermissionSelection({'mode': 'bypassPermissions'})),
        (AgentIds.codex, const PermissionSelection({'sandbox': 'bypass-all'})),
        (AgentIds.antigravity, const PermissionSelection({'mode': 'skip-permissions'})),
      ]) {
        final support = supportOf(agentId);
        expect(support.riskOf(selection), PermissionRisk.bypass, reason: agentId);
        expect(
          describeSelectionFamiliar(support, selection),
          describeSelection(support, selection),
          reason: agentId,
        );
      }
    });
  });

  test('the evidence each value carries is untouched', () {
    // The pairing is a display rule and nothing else: every value still says
    // where it was read off, which is what a future CLI version is re-checked
    // against.
    for (final agentId in AgentIds.builtIn) {
      for (final axis in supportOf(agentId).axes) {
        for (final value in axis.values) {
          expect(value.evidence, isNotEmpty, reason: '$agentId/${value.id}');
        }
      }
    }
  });
}
