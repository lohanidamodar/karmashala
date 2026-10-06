import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../../core/data/data_client.dart';
import '../../../../core/data/data_providers.dart';

/// The server's activity log, asked for by range; nothing of it is copied
/// here but what a timeline on screen asked for.
class TimelineData {
  TimelineData(this._client);

  final DataClient _client;

  /// Entries the server appended, as they land.
  Stream<List<ActivityEntry>> get appended => _client.activityAppended;

  /// Every entry from [from] up to [to] for [projectIds] (null for all),
  /// every page of it, oldest first.
  Future<List<ActivityEntry>> range({
    required DateTime from,
    required DateTime to,
    List<String>? projectIds,
  }) async {
    final entries = <ActivityEntry>[];
    ActivityCursor? after;
    do {
      final page = (await _client.send(
        ActivityRange(from: from, to: to, projectIds: projectIds, after: after),
      )).value;
      entries.addAll(page.entries);
      after = page.next;
    } while (after != null);
    return entries;
  }
}

final timelineDataProvider = Provider<TimelineData>(
  (ref) => TimelineData(ref.watch(dataClientProvider)),
);
