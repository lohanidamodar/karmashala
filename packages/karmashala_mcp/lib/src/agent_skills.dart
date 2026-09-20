/// The skills Karmashala installs into the agent CLIs: what `instructions()`
/// says, through a door the CLI discovers. Rosters come from [kMcpGuides].
library;

import 'package:agent_cli/descriptors.dart';
import 'instructions_tools.dart';

/// Every skill this app installs, in the order Settings counts them.
final List<KarmashalaSkill> kKarmashalaSkills = <KarmashalaSkill>[
  _instructionsSkill(),
  _advisorSkill,
  _committeeSkill,
];

/// The cheap one, and the one the other two lean on.
KarmashalaSkill _instructionsSkill() => KarmashalaSkill(
  name: 'karmashala-instructions',
  description:
      'Karmashala\'s own operating guides: what a tool\'s success does NOT '
      'prove, which refusals are permanent, and which acts have no undo. Use '
      'before the first time you touch a family of Karmashala tools in a '
      'task, and whenever one returns something you did not expect.',
  body:
      '''
# Karmashala's operating guides

Karmashala serves its guides as a tool rather than as files, so they are one
call away and always describe the build you are talking to. **Call
`instructions` with the topic for what you are about to do**, before the first
call in that family — not after one has surprised you.

    instructions(topic: "sessions")

The topics, generated from the same table the tool reads:

${_topicRoster()}

`instructions()` with no topic prints that list again.

These say what a tool's success does **not** prove, which is the part a tool
description has no room for: that a delivered `session_send` says nothing about
the agent on the other side having read it, that `terminal_run` reports
`exitCodeKnown: false` rather than inventing a zero, that `worktree_create`
makes a folder and a branch and delegates nothing.

If `instructions` is not among your tools, Karmashala is not connected to this
session — and neither is anything the rest of these skills name.
''',
);

/// The topic listing, from the same guides `instructions` serves.
String _topicRoster() => <String>[
  for (final guide in kMcpGuides) '  ${guide.topic} — ${guide.summary}',
].join('\n');

const KarmashalaSkill _advisorSkill = KarmashalaSkill(
  name: 'karmashala-advisor',
  description:
      'Get a second opinion from an agent of a different family without '
      'handing over the work. Use when you are about to commit to a design, a '
      'risky change or a diagnosis you cannot check yourself, and you want it '
      'challenged rather than taken over.',
  body: '''
# Ask for a second opinion, and keep the work

An advisor reads what you did and says where it is wrong. It does not take the
task, does not edit files and does not get a worktree.

**A fork is not an advisor.** `session_fork` branches *this* conversation and
runs the SAME agent, so what comes back is you again with your own reasoning
already inside it — the one thing a second opinion must not be. `session_handoff`
is further off still: it continues the work somewhere else. Both are the right
tool for other jobs.

**A contrasting profile means a different provider family.** `list_agents`
returns every installed agent on this machine as an (agentInstallationId, cli,
environmentId). Karmashala ships knowledge of three families and they do not
fail in the same places. Pick one whose `cli` is not the one you are running as.

## Asking

1. `list_agents`, and choose an installation from another family.
2. `open_new_session` with that `agentInstallationId`, the same `projectId`,
   **no worktree**, and a prompt holding the decision, the evidence you already
   have, and the question. Say you want a critique and no edits — an agent given
   a problem will otherwise solve it.
3. `session_wait` on the id you get back. `idle` means ready for input and is
   never proof it answered you; `done` is idle-and-seen-changed. Then
   `session_transcript`.
4. `session_end` when you have the answer. The transcript survives; the turn in
   flight does not.

## Reading the answer

It is a peer's opinion. Your prompt arrived with your session's name on it and
carries exactly the authority you had — so the reply is not the user speaking
and is not a fact. **Where the advisor and the files disagree, the files win**:
check the claim before you act on it.

If it changes what you were going to do, `decision_record` is where that goes,
with what changed your mind. If it does not, you have paid one session to find
that out, which is the point.

Two advisors on one question is `karmashala-committee`. That is a different
skill because it costs twice as much and answers a different problem.
''',
);

const KarmashalaSkill _committeeSkill = KarmashalaSkill(
  name: 'karmashala-committee',
  description:
      'Convene two agents from deliberately different provider families to '
      'find a root cause in parallel. Use when you are stuck or looping — a '
      'fix that has failed twice, a test that fails differently each run, a '
      'symptom nobody has explained — and not for ordinary work.',
  body: '''
# Two agents, different families, one question

A committee is for a diagnosis you have already failed to reach: the same fix
attempted twice, a failure that changes shape between runs, a symptom nothing
you have read explains. Ordinary work does not need one, and two agents
agreeing is what you get for convening one too early.

**Look for the one that already sat.** `fanout_list` and `fanout_get` read the
comparisons the *user* ran from Karmashala — one prompt, several agents,
parallel worktrees, each with its diff and its outcome. Neither tool starts
one; fan-out is something the user does in the app. Check there before you
spend two sessions on a question that has an answer.

**Different families, deliberately.** `list_agents` gives every installed
(agentInstallationId, cli, environmentId). Pick two whose `cli` differ: two
sessions of one CLI reach the same wrong answer twice, and their agreement
teaches you nothing. You cannot choose a member's model or reasoning effort
from here — that is Karmashala's own setting — so ask for the cause in the
prompt rather than assuming you were given a careful reader.

## Convening

1. Two `open_new_session` calls with different `cli`s, the same `projectId`,
   and a worktree each. Separate worktrees are what stops two diagnoses editing
   one file.
2. Give both the **same prompt**: the symptom, the exact command and its output,
   what you already tried and what it did. Ask for the cause and the evidence
   for it. A committee asked to fix something returns two fixes and no
   diagnosis.
3. `session_wait` on each, then `session_transcript` on both **before** you
   judge either. Reading the first alone is one opinion at twice the price.
4. `session_end` both, and `worktree_remove` what you no longer need.

## Reading the disagreement

Two independent agents landing on the same cause is the strongest signal
available here. Two different causes is not a tie to break: it means at least
one of them is reasoning from something you did not give them, and finding what
that was is usually faster than arbitrating. Where either one and the files
disagree, the files win.

Record what it concluded with `decision_record`, so the next agent to meet this
does not convene the same committee again.
''',
);
