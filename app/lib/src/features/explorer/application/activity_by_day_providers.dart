import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'activity_by_day.dart';
import 'agent_state_providers.dart';
import 'agent_states.dart';
import 'workspace_session_entry.dart';

/// Every chat across projects by the local day it was last active, for the
/// by-day lens. Built only while that lens is on screen, and again only when
/// the session list changes — the day boundary is read once per build, never
/// from a timer.
final activityDaysProvider =
    Provider.autoDispose<List<DayBucket<WorkspaceSessionEntry>>>((ref) {
      final sessions = ref.watch(workspaceSessionsProvider);
      final today = ref.read(clockProvider).nowUtc().toLocal();
      return bucketByDay(
        sessions,
        timeOf: (entry) => entry.activityAt.toLocal(),
        today: today,
        tieBreak: compareByActivity,
      );
    });
