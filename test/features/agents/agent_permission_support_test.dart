import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/settings/domain/permission_risk.dart';

/// The declared permission vocabularies, held to what the binaries said.
///
/// These are goldens on purpose. Every argument list here was read off a CLI on
/// this machine, and the failure this file exists to catch is the one no other
/// test can: a flag asserted against a string literal that is itself the
/// mistake. When a CLI changes, this file changes with the descriptor and the
/// evidence string beside it says which version it was re-read from.
void main() {
  final registry = AgentRegistry.builtIn;
  AgentPermissionSupport supportFor(String id) =>
      registry.byId(id)!.launch.permission;

  group('every declared agent', () {
    for (final descriptor in registry.descriptors) {
      final support = descriptor.launch.permission;

      test('${descriptor.id} declares its evidence', () {
        expect(support.isKnown, isTrue);
        expect(support.evidence, isNotEmpty);
        for (final axis in support.axes) {
          expect(axis.values, isNotEmpty, reason: '${axis.id} has no values');
          for (final value in axis.values) {
            expect(
              value.evidence,
              isNotEmpty,
              reason: '${descriptor.id}/${axis.id}/${value.id} claims a mode '
                  'without saying where it was read',
            );
          }
        }
      });

      test('${descriptor.id} never defaults to something dangerous', () {
        // Architecture constraint 12, asserted rather than reviewed.
        expect(
          support.isDangerous(support.defaultSelection),
          isFalse,
          reason: '${descriptor.id} would start sessions in a bypass',
        );
        for (final axis in support.axes) {
          expect(
            axis.valueFor(axis.defaultValueId),
            isNotNull,
            reason: '${axis.id} defaults to a value it does not declare',
          );
        }
      });

      test('${descriptor.id} orders every axis safest-first', () {
        for (final axis in support.axes) {
          final permits = [for (final v in axis.values) v.permits.index];
          final sorted = [...permits]..sort();
          expect(
            permits,
            sorted,
            reason: '${axis.id} lists a more permissive value before a safer '
                'one; the order is what every picker renders',
          );
        }
      });
    }
  });

  group('Claude Code', () {
    final support = supportFor('claudeCode');

    test('has all six modes the CLI enforces', () {
      // `claude --permission-mode bogus --help` on 2.1.245 and 2.1.259:
      // "Allowed choices are acceptEdits, auto, bypassPermissions, manual,
      // dontAsk, plan."
      expect(
        [for (final v in support.axes.single.values) v.id],
        ['plan', 'dontAsk', 'manual', 'acceptEdits', 'auto', 'bypassPermissions'],
      );
    });

    test('asks for each one by name', () {
      for (final value in support.axes.single.values) {
        expect(value.arguments, ['--permission-mode', value.id]);
      }
    });

    test('defaults to manual, not to passing nothing', () {
      // Passing no flag is not the same thing: 2.1.228+ starts Pro/Max/Team
      // sessions in `auto`, so the safe mode has to be named.
      expect(support.defaultSelection.valueFor('mode'), 'manual');
      expect(support.argumentsFor(support.defaultSelection), [
        '--permission-mode',
        'manual',
      ]);
    });
  });

  group('Codex', () {
    final support = supportFor('codex');
    PermissionSelection pick(String sandbox, String approval) =>
        PermissionSelection({'sandbox': sandbox, 'approval': approval});

    test('is two axes', () {
      expect([for (final a in support.axes) a.id], ['sandbox', 'approval']);
    });

    test('composes the two by min, not max', () {
      // A read-only sandbox cannot write however the approval policy is set,
      // so the sandbox is what bounds `never` rather than the other way round.
      expect(support.riskOf(pick('read-only', 'never')), PermissionRisk.readOnly);
      expect(
        support.riskOf(pick('workspace-write', 'on-request')),
        PermissionRisk.acceptEdits,
      );
      expect(
        support.riskOf(pick('danger-full-access', 'never')),
        PermissionRisk.bypass,
      );
    });

    test('reproduces the argument list the old accept-edits mapping sent', () {
      // The one mapping that must survive the move byte for byte: it is what
      // every stored Codex session is migrated onto.
      expect(support.argumentsFor(pick('workspace-write', 'on-request')), [
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'on-request',
      ]);
    });

    test('the bypass flag supersedes the approval axis', () {
      final selection = pick('bypass-all', 'never');
      expect(support.argumentsFor(selection), [
        '--dangerously-bypass-approvals-and-sandbox',
      ]);
      expect(support.isDangerous(selection), isTrue);
      // Every approval choice collapses onto one row rather than three.
      expect(
        support.normalise(pick('bypass-all', 'never')),
        support.normalise(pick('bypass-all', 'on-request')),
      );
    });

    test('a dangerous combination of two ordinary picks is still dangerous', () {
      // Neither value carries a warning of its own; together they leave
      // nothing in the way.
      expect(support.isDangerous(pick('danger-full-access', 'never')), isTrue);
      expect(support.isDangerous(pick('workspace-write', 'on-request')), isFalse);
    });

    test('declares only what the latest Codex accepts', () {
      // 0.151.0 rejects `untrusted`; 0.145.0 accepts everything below. The
      // latest set is a subset of the older one, so it launches on both.
      expect([for (final v in support.axes[1].values) v.id], [
        'on-request',
        'never',
      ]);
    });

    test('has no "ask before anything" left, and does not pretend to', () {
      // The stated cost of declaring from the latest version: `untrusted` was
      // the only value at this rung. A handoff has to fall to read-only and
      // say so rather than claim an ask-every-time Codex cannot do.
      final rungs = [for (final s in support.selections()) support.riskOf(s)];
      expect(rungs, isNot(contains(PermissionRisk.ask)));
      expect(rungs, contains(PermissionRisk.readOnly));
    });

    test('enumerates 7 selections, not 8', () {
      // 4 sandbox x 2 approval, with the bypass flag's two rows collapsed into
      // one because it supersedes the approval axis.
      expect(support.selections(), hasLength(7));
    });
  });

  group('Antigravity', () {
    final support = supportFor('antigravity');

    test('has plan mode, and its ask is the unflagged behaviour', () {
      expect([for (final v in support.axes.single.values) v.id], [
        'plan',
        'prompt',
        'accept-edits',
        'skip-permissions',
      ]);
      expect(support.argumentsFor(support.defaultSelection), isEmpty);
    });

    test('asks for the modes agy --help names', () {
      final axis = support.axes.single;
      expect(axis.valueFor('plan')!.arguments, ['--mode', 'plan']);
      expect(axis.valueFor('accept-edits')!.arguments, [
        '--mode',
        'accept-edits',
      ]);
      expect(axis.valueFor('skip-permissions')!.arguments, [
        '--dangerously-skip-permissions',
      ]);
    });
  });

  group('an agent nobody has established', () {
    const support = AgentPermissionSupport.unknown();

    test('offers nothing and claims nothing', () {
      expect(support.isKnown, isFalse);
      expect(support.selections(), isEmpty);
      expect(support.argumentsFor(null), isEmpty);
      // Not `ask`: a rung would be a claim about an unverified default.
      expect(support.riskOf(null), isNull);
      expect(support.isDangerous(null), isFalse);
    });
  });

  group('"enforce nothing" is not "use the default"', () {
    final support = supportFor('claudeCode');

    test('an empty selection passes no flags and survives a round trip', () {
      // The two states look alike and must never behave alike. A *null*
      // selection means "nobody chose, use the declared default" and does pass
      // flags; an *empty* one is the carry rule's answer when every mode an
      // agent has is more permissive than what the user asked for, and passing
      // the default there would silently widen the very case the rule narrows.
      expect(support.argumentsFor(null), isNotEmpty);
      expect(support.argumentsFor(PermissionSelection.empty), isEmpty);
      expect(support.riskOf(PermissionSelection.empty), isNull);
      expect(support.isDangerous(PermissionSelection.empty), isFalse);
      // Through a session row / the settings file / the wire and back.
      expect(PermissionSelection.empty.canonical, 'none');
      expect(
        PermissionSelection.parse(PermissionSelection.empty.canonical),
        PermissionSelection.empty,
      );
      expect(
        support.resolveStored(PermissionSelection.empty.canonical),
        PermissionSelection.empty,
      );
      // And a genuinely absent preference still resolves to the default.
      expect(support.resolveStored(null), support.defaultSelection);
    });
  });

  group('legacy names written before v35', () {
    test('every agent translates all three, matching the v35 migration', () {
      // The migration rewrites session rows; this table is what reads a
      // settings file, which no SQL touches. They must agree.
      const expected = {
        'claudeCode': {
          'ask': 'mode=manual',
          'acceptEdits': 'mode=acceptEdits',
          'bypass': 'mode=bypassPermissions',
        },
        'antigravity': {
          'ask': 'mode=prompt',
          'acceptEdits': 'mode=accept-edits',
          'bypass': 'mode=skip-permissions',
        },
        'codex': {
          'ask': 'approval=on-request;sandbox=workspace-write',
          'acceptEdits': 'approval=on-request;sandbox=workspace-write',
          'bypass': 'approval=on-request;sandbox=bypass-all',
        },
      };
      for (final entry in expected.entries) {
        final support = supportFor(entry.key);
        expect(support.legacyAliases, entry.value, reason: entry.key);
        for (final legacy in entry.value.keys) {
          expect(
            support.resolveStored(legacy).canonical,
            entry.value[legacy],
            reason: '${entry.key}/$legacy',
          );
        }
      }
    });

    test('Claude Code and Antigravity keep their exact old flags', () {
      // Argument-preserving for two of the three: no migrated session's
      // command line changes by a character.
      final claude = supportFor('claudeCode');
      expect(claude.argumentsFor(claude.resolveStored('ask')), [
        '--permission-mode',
        'manual',
      ]);
      expect(claude.argumentsFor(claude.resolveStored('bypass')), [
        '--permission-mode',
        'bypassPermissions',
      ]);
      final agy = supportFor('antigravity');
      expect(agy.argumentsFor(agy.resolveStored('ask')), isEmpty);
      expect(agy.argumentsFor(agy.resolveStored('acceptEdits')), [
        '--mode',
        'accept-edits',
      ]);
    });

    test('Codex ask gains a sandbox flag, and that is the only change', () {
      // The one cell that changes, by one added flag. It used to send only
      // `--ask-for-approval on-request`, which the old descriptor itself
      // documented as not being an ask-every-time.
      final codex = supportFor('codex');
      expect(codex.argumentsFor(codex.resolveStored('ask')), [
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'on-request',
      ]);
      expect(
        codex.argumentsFor(codex.resolveStored('bypass')),
        ['--dangerously-bypass-approvals-and-sandbox'],
      );
    });
  });

  group('PermissionSelection', () {
    test('round-trips through its canonical form', () {
      const selection = PermissionSelection({
        'sandbox': 'workspace-write',
        'approval': 'on-request',
      });
      expect(selection.canonical, 'approval=on-request;sandbox=workspace-write');
      expect(PermissionSelection.parse(selection.canonical), selection);
    });

    test('refuses malformed input rather than inventing a selection', () {
      expect(PermissionSelection.parse(null), isNull);
      expect(PermissionSelection.parse(''), isNull);
      expect(PermissionSelection.parse('nonsense'), isNull);
      expect(PermissionSelection.parse('=value'), isNull);
      expect(PermissionSelection.parse('axis='), isNull);
    });

    test('an unrecognised value is reported, not silently swapped', () {
      final support = supportFor('claudeCode');
      const stored = PermissionSelection({'mode': 'somethingNewer'});
      expect(support.unknownAxes(stored), ['mode']);
      expect(support.normalise(stored).valueFor('mode'), 'manual');
    });
  });

}
