import 'package:agent_cli/descriptors.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;

import '../../explorer/application/agent_states.dart';
import 'overview_reads.dart';

/// What a session is doing, in words, and the raw text behind it — a
/// command — which is shown only folded away, never as the [headline].
@immutable
class OverviewActivity {
  const OverviewActivity(this.headline, {this.raw});

  final String headline;
  final String? raw;

  @override
  bool operator ==(Object other) =>
      other is OverviewActivity &&
      other.headline == headline &&
      other.raw == raw;

  @override
  int get hashCode => Object.hash(headline, raw);

  @override
  String toString() => 'OverviewActivity($headline, raw: $raw)';
}

/// **What a session is doing, for a person.** In order: the running call's
/// own words, the agent's current plan step, then its state in words. Built
/// only from what the app holds — the status report, the inbox's words
/// ([detailOf]) and one server read ([glance]).
OverviewActivity overviewActivity({
  required AgentState state,
  required AgentStatusReport? report,
  required String? Function(InboxItemKind kind) detailOf,
  required DateTime activityAt,
  required DateTime now,
  OverviewGlance? glance,
}) {
  String age(DateTime at) => compactAge(now.difference(at));
  String aged(String what, DateTime? since) =>
      since == null ? what : '$what · ${age(since)}';
  switch (state) {
    case AgentState.needsYou:
      final since = report?.waitingSince;
      final ask = report?.waiting == AgentWaitKind.approval
          ? report?.toolAsk
          : null;
      if (ask != null) {
        final described = switch (ask.input['description']) {
          final String text when text.trim().isNotEmpty => text.trim(),
          _ => null,
        };
        final summary = summarizeToolAsk(ask);
        if (described != null) {
          return OverviewActivity(
            aged('Asks to: $described', since),
            raw: summary.isCommand ? summary.subject : null,
          );
        }
        if (summary.isCommand) {
          return OverviewActivity(
            aged('Asks to run a command', since),
            raw: summary.subject.isEmpty ? null : summary.subject,
          );
        }
        final subject = _lastSegment(summary.subject);
        return OverviewActivity(
          aged(
            subject.isEmpty
                ? 'Asks to ${summary.action}'
                : 'Asks to ${summary.action}: $subject',
            since,
          ),
        );
      }
      if (report?.waiting == AgentWaitKind.question) {
        return OverviewActivity(aged('Asks a question', since));
      }
      if (detailOf(InboxItemKind.needsApproval) case final detail?) {
        return looksLikeCommand(detail)
            ? OverviewActivity(aged('Asks for approval', since), raw: detail)
            : OverviewActivity(aged('Asks: $detail', since));
      }
      return OverviewActivity(aged('Waiting on you', since));
    case AgentState.failed:
      final detail = detailOf(InboxItemKind.failed);
      return OverviewActivity(detail == null ? 'Failed' : 'Failed: $detail');
    case AgentState.working:
      return _working(report, glance, aged, activityAt);
    case AgentState.quiet:
      final at = report?.quietSince;
      return OverviewActivity(
        at == null
            ? 'Quiet: nothing new recorded'
            : 'Nothing new for ${age(at)}',
      );
    case AgentState.ready:
      return OverviewActivity(
        detailOf(InboxItemKind.finished) ??
            'Finished its turn · waiting for you',
      );
    case AgentState.ended:
      final detail =
          detailOf(InboxItemKind.followUp) ?? detailOf(InboxItemKind.finished);
      return OverviewActivity(
        detail == null ? 'Ended ${age(activityAt)} ago' : 'Done: $detail',
      );
  }
}

OverviewActivity _working(
  AgentStatusReport? report,
  OverviewGlance? glance,
  String Function(String what, DateTime? since) aged,
  DateTime activityAt,
) {
  final open = glance?.open ?? const <OverviewOpenCall>[];
  final worded = [
    for (final c in open)
      if (c.phrase != null) c,
  ];
  final unworded = open.where((c) => c.phrase == null && c.raw != null);
  if (worded.isNotEmpty) {
    // The newest call of the agent's own turn leads a background run.
    final own = worded.where((c) => !c.background);
    final lead = own.isNotEmpty ? own.last : worded.last;
    final more = worded.length - 1;
    return OverviewActivity(
      aged('${lead.phrase}${more > 0 ? ' +$more' : ''}', lead.since),
      raw: lead.raw,
    );
  }
  final raw = unworded.isEmpty ? null : unworded.last.raw;
  final plan = glance?.plan;
  if (plan != null && !plan.isFinished) {
    final step = plan.current?.text;
    final at = (plan.doneCount + (step == null ? 0 : 1)).clamp(1, plan.total);
    return OverviewActivity(
      step == null
          ? 'Plan ${plan.doneCount}/${plan.total} done'
          : 'Step $at/${plan.total}: $step',
      raw: raw,
    );
  }
  if (unworded.isNotEmpty) {
    final lead = unworded.last;
    return OverviewActivity(
      aged(
        lead.background ? 'Running a background command' : 'Running a command',
        lead.since,
      ),
      raw: lead.raw,
    );
  }
  final running = report?.inFlight ?? const <String>[];
  if (running.isNotEmpty) {
    final words = running.where((r) => !looksLikeCommand(r)).toList();
    final more = running.length - 1;
    final tail = more > 0 ? ' +$more' : '';
    if (words.isNotEmpty) {
      return OverviewActivity('In the background: ${words.first}$tail');
    }
    return OverviewActivity(
      'Running a background command$tail',
      raw: running.first,
    );
  }
  final said = report?.evidence.lastWhere(
    (line) => line.trim().isNotEmpty,
    orElse: () => '',
  );
  if (said != null && said.trim().isNotEmpty) {
    return looksLikeCommand(said)
        ? OverviewActivity('Working', raw: said.trim())
        : OverviewActivity(said.trim());
  }
  return const OverviewActivity('Working');
}

String _lastSegment(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// [overviewActivity]'s headline alone, for a line with no room for more.
String overviewContextLine({
  required AgentState state,
  required AgentStatusReport? report,
  required String? Function(InboxItemKind kind) detailOf,
  required DateTime activityAt,
  required DateTime now,
  OverviewGlance? glance,
}) => overviewActivity(
  state: state,
  report: report,
  detailOf: detailOf,
  activityAt: activityAt,
  now: now,
  glance: glance,
).headline;
