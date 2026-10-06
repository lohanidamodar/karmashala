import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;

import '../../explorer/application/agent_states.dart';

/// A card's one line: what the session is doing, or why it is on the Board.
/// Built only from what the app holds — the status report and the inbox's
/// words ([detailOf]) — so where neither says anything, it says the state.
String overviewContextLine({
  required AgentState state,
  required AgentStatusReport? report,
  required String? Function(InboxItemKind kind) detailOf,
  required DateTime activityAt,
  required DateTime now,
}) {
  String age(DateTime at) => compactAge(now.difference(at));
  switch (state) {
    case AgentState.needsYou:
      final since = report?.waitingSince;
      final ask = report?.waiting == AgentWaitKind.approval
          ? report?.toolAsk
          : null;
      final String what;
      if (ask != null) {
        final summary = summarizeToolAsk(ask);
        final verb = summary.isCommand ? 'run' : summary.action;
        what = summary.subject.isEmpty
            ? 'asks to $verb'
            : 'asks: $verb ${summary.subject}';
      } else if (report?.waiting == AgentWaitKind.question) {
        what = 'asks a question';
      } else if (detailOf(InboxItemKind.needsApproval) case final detail?) {
        what = 'asks: $detail';
      } else {
        what = 'waiting on you';
      }
      return since == null ? what : '$what · ${age(since)}';
    case AgentState.failed:
      final detail = detailOf(InboxItemKind.failed);
      return detail == null ? 'failed' : 'failed: $detail';
    case AgentState.working:
      final running = report?.inFlight ?? const [];
      if (running.isNotEmpty) {
        final more = running.length - 1;
        return 'running ${running.first}${more > 0 ? ' +$more' : ''}';
      }
      final said = report?.evidence.lastWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => '',
      );
      return said == null || said.isEmpty ? 'working' : said.trim();
    case AgentState.quiet:
      final at = report?.evidenceAt;
      return at == null ? 'quiet' : 'nothing new for ${age(at)}';
    case AgentState.ready:
      return detailOf(InboxItemKind.finished) ?? 'ready · ${age(activityAt)}';
    case AgentState.ended:
      final detail =
          detailOf(InboxItemKind.followUp) ?? detailOf(InboxItemKind.finished);
      return detail == null ? 'ended ${age(activityAt)} ago' : 'done: $detail';
  }
}
