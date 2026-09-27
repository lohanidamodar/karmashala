part of '../data_change.dart';

// Session status and attention (slice 5c), told to every subscribed client:
// each status the server keeps as it moves, the inbox whole whenever it
// changes, each piece of agent news for a client's toasts, and a window's
// cue to show a session (`inbox.open`, from any client or an agent's
// `inbox_open`). A subscriber is greeted with every status and the inbox.

DataChange? _attentionChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'sessionStatusChanged' => SessionStatusChanged(
        SessionStatusEntry.fromJson(_row(json)),
      ),
      'sessionStatusRemoved' => SessionStatusRemoved(json['id']! as String),
      'watchCoverageChanged' => WatchCoverageChanged(
        WatchCoverage.fromJson(_row(json)),
      ),
      'inboxChanged' => InboxChanged(AttentionSnapshot.fromJson(_row(json))),
      'attentionNews' => AttentionNewsTold(AttentionNews.fromJson(_row(json))),
      'inboxOpenWanted' => InboxOpenWanted(
        openId: json['openId']! as String,
        imported: json['imported'] == true,
        itemId: json['itemId'] as String?,
      ),
      'forgeReadingChanged' => ForgeReadingChanged(
        environmentPathFromJson((json['checkout']! as Map).cast()),
        PullRequestReading.fromJson(_row(json)),
      ),
      'usageLimitNoticed' => UsageLimitNoticed(
        UsageLimitNotice.fromJson(_row(json)),
      ),
      _ => null,
    };

/// What the server's status and attention did.
sealed class AttentionChange extends DataChange {
  const AttentionChange();
}

/// A watched session's status moved (or the session joined the watch set).
final class SessionStatusChanged extends AttentionChange {
  const SessionStatusChanged(this.entry);

  final SessionStatusEntry entry;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionStatusChanged',
    'row': entry.toJson(),
  };
}

/// Session [openId] left the watch set: the server keeps no status for it.
final class SessionStatusRemoved extends AttentionChange {
  const SessionStatusRemoved(this.openId);

  final String openId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionStatusRemoved',
    'id': openId,
  };
}

/// The server's last cycle reached a different part of the watch set.
final class WatchCoverageChanged extends AttentionChange {
  const WatchCoverageChanged(this.coverage);

  final WatchCoverage coverage;

  @override
  Map<String, Object?> toJson() => {
    'change': 'watchCoverageChanged',
    'row': coverage.toJson(),
  };
}

/// The inbox, or who is waiting, changed: here it is whole.
final class InboxChanged extends AttentionChange {
  const InboxChanged(this.snapshot);

  final AttentionSnapshot snapshot;

  @override
  Map<String, Object?> toJson() => {
    'change': 'inboxChanged',
    'row': snapshot.toJson(),
  };
}

/// Agent news the server saw — a turn finished, a prompt opened, a turn
/// failed — for a client's presenter to judge against its own focus.
final class AttentionNewsTold extends AttentionChange {
  const AttentionNewsTold(this.news);

  final AttentionNews news;

  @override
  Map<String, Object?> toJson() => {
    'change': 'attentionNews',
    'row': news.toJson(),
  };
}

/// Show session [openId] ([imported] when it is imported history): an inbox
/// item [itemId] was opened, by a client or an agent's `inbox_open`.
final class InboxOpenWanted extends AttentionChange {
  const InboxOpenWanted({
    required this.openId,
    required this.imported,
    this.itemId,
  });

  final String openId;
  final bool imported;
  final String? itemId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'inboxOpenWanted',
    'openId': openId,
    if (imported) 'imported': true,
    'itemId': ?itemId,
  };
}

/// What the forge says about checkout [checkout]'s branch now — its pull
/// request and checks, merge settings and review threads — read by the
/// server's own delivery poll (slice 5c: the server reads it every two
/// minutes and when a turn ends there, app or no app). A subscriber is
/// greeted with every reading the server keeps.
final class ForgeReadingChanged extends AttentionChange {
  const ForgeReadingChanged(this.checkout, this.reading);

  final EnvironmentPath checkout;
  final PullRequestReading reading;

  @override
  Map<String, Object?> toJson() => {
    'change': 'forgeReadingChanged',
    'checkout': environmentPathToJson(checkout),
    'row': reading.toJson(),
  };
}

/// A session's turn ended on a usage limit, and what the server did about it
/// (offered, armed, armed again, refused) — for a client's notice.
final class UsageLimitNoticed extends AttentionChange {
  const UsageLimitNoticed(this.notice);

  final UsageLimitNotice notice;

  @override
  Map<String, Object?> toJson() => {
    'change': 'usageLimitNoticed',
    'row': notice.toJson(),
  };
}
