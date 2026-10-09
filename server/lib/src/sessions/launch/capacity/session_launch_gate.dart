import 'dart:async';
import 'dart:convert';

import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// The server-owned queue every agent launch passes: a session a person
/// starts, a resume, an automation's run, a pipeline's stage. It reads the
/// person's limits, counts what holds a slot now and grants or queues.
///
/// Waiting launches are persisted (`launch_queue.v1`) and handed back, after
/// a restart too, to the dispatcher registered for their [LaunchClaim.kind].
const String kLaunchQueueKey = 'launch_queue.v1';

/// What one launch would hold, and how to start it later.
final class LaunchClaim {
  const LaunchClaim({
    required this.kind,
    required this.priority,
    required this.environmentId,
    required this.accountKey,
    required this.projectId,
    required this.label,
    this.sessionId,
    this.payload = const {},
    this.personStarted = false,
  });

  /// Whose dispatcher starts it once granted: `session.start`,
  /// `pipeline.stage`, …
  final String kind;
  final LaunchPriority priority;
  final String environmentId;

  /// `usageAccountKey(installation)`.
  final String accountKey;
  final String projectId;
  final String label;

  /// The row the wait shows on, when there is one.
  final String? sessionId;

  /// What [kind]'s dispatcher needs to start it, as JSON.
  final Map<String, Object?> payload;
  final bool personStarted;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'priority': priority.name,
    'environmentId': environmentId,
    'accountKey': accountKey,
    'projectId': projectId,
    'label': label,
    if (sessionId != null) 'sessionId': sessionId,
    if (payload.isNotEmpty) 'payload': payload,
    if (personStarted) 'personStarted': true,
  };

  static LaunchClaim? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    if (kind is! String) return null;
    final payload = json['payload'];
    return LaunchClaim(
      kind: kind,
      priority: LaunchPriority.parse(json['priority']),
      environmentId: json['environmentId'] as String? ?? '',
      accountKey: json['accountKey'] as String? ?? '',
      projectId: json['projectId'] as String? ?? '',
      label: json['label'] as String? ?? '',
      sessionId: json['sessionId'] as String?,
      payload: payload is Map ? payload.cast<String, Object?>() : const {},
      personStarted: json['personStarted'] == true,
    );
  }
}

/// A queued [LaunchClaim].
final class LaunchTicket {
  const LaunchTicket({
    required this.id,
    required this.claim,
    required this.enqueuedAt,
  });

  final String id;
  final LaunchClaim claim;
  final DateTime enqueuedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'claim': claim.toJson(),
    'enqueuedAt': enqueuedAt.toUtc().toIso8601String(),
  };

  static LaunchTicket? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final claim = LaunchClaim.fromJson(json['claim']);
    final at = DateTime.tryParse(json['enqueuedAt'] as String? ?? '');
    if (id is! String || claim == null || at == null) return null;
    return LaunchTicket(id: id, claim: claim, enqueuedAt: at.toUtc());
  }
}

/// A slot held for a launch in flight, until its process is live (when the
/// process itself holds it) or the launch failed. [release] twice is fine.
final class LaunchReservation {
  LaunchReservation._(this._gate, this.claim, this.takenAt);

  final SessionLaunchGate _gate;
  final LaunchClaim claim;
  final DateTime takenAt;
  bool _released = false;
  final Completer<void> _done = Completer<void>();

  bool get isReleased => _released;

  /// Completes once [release] is called.
  Future<void> get released => _done.future;

  void release() {
    if (_released) return;
    _released = true;
    _done.complete();
    _gate._reservations.remove(this);
    _gate.pump();
  }
}

sealed class LaunchAdmission {
  const LaunchAdmission();
}

final class LaunchGranted extends LaunchAdmission {
  const LaunchGranted(this.reservation);
  final LaunchReservation reservation;
}

final class LaunchWaiting extends LaunchAdmission {
  const LaunchWaiting(this.ticket, {required this.reason, required this.place});
  final LaunchTicket ticket;
  final String reason;
  final int place;

  SessionWait get asSessionWait =>
      SessionWait(ticketId: ticket.id, reason: reason, place: place);
}

/// A live agent session that holds a slot by [kLaunchSlotRule].
final class SlotHolder {
  const SlotHolder({
    required this.sessionId,
    required this.label,
    required this.environmentId,
    required this.accountKey,
    required this.projectId,
  });

  final String sessionId;
  final String label;
  final String environmentId;
  final String accountKey;
  final String projectId;
}

typedef LaunchDispatch =
    Future<void> Function(LaunchTicket ticket, LaunchReservation reservation);

/// Scope names in a person's words; each falls back to its key.
final class LaunchScopeNames {
  const LaunchScopeNames({this.machine, this.account, this.project});
  final String Function(String environmentId)? machine;
  final String Function(String accountKey)? account;
  final String Function(String projectId)? project;

  String of(CapacityScope scope, String key) => switch (scope) {
    CapacityScope.global => 'all machines',
    CapacityScope.machine => machine?.call(key) ?? key,
    CapacityScope.account => account?.call(key) ?? key,
    CapacityScope.project => project?.call(key) ?? key,
  };
}

/// See [kLaunchQueueKey]. Single-isolate and synchronous between counting
/// and reserving, so two launches at once never oversubscribe a limit.
class SessionLaunchGate {
  SessionLaunchGate({
    required this.limits,
    required this.occupants,
    required this.clock,
    this.readQueue,
    this.writeQueue,
    this.fiveHourPercent,
    this.names = const LaunchScopeNames(),
    String Function()? newId,
    this.log,
    this.reservationTimeout = const Duration(minutes: 10),
  }) : _newId = newId ?? _counterId();

  final LaunchLimits Function() limits;

  /// The live sessions holding a slot now — rebuilt from the processes on
  /// every count, so an ended, failed, stopped or archived one frees its slot
  /// without being told, and a restart needs no reconciling of its own.
  final List<SlotHolder> Function() occupants;
  final Clock clock;
  final String? Function()? readQueue;
  final void Function(String json)? writeQueue;

  /// An account's 5-hour window, in percent; null is unknown and never holds.
  final double? Function(String accountKey)? fiveHourPercent;
  final LaunchScopeNames names;
  final void Function(String message)? log;

  /// A reservation whose launch never reported back stops counting after this.
  final Duration reservationTimeout;
  final String Function() _newId;

  final List<LaunchTicket> _queue = [];
  final List<LaunchReservation> _reservations = [];
  final Map<
    String,
    ({
      LaunchDispatch dispatch,
      void Function(LaunchTicket)? cancelled,
      bool restorable,
    })
  >
  _dispatchers = {};
  final Map<String, String> _reasons = {};
  final StreamController<void> _changes = StreamController.broadcast();
  String? _lastFingerprint;
  bool _started = false;
  bool _pumping = false;
  bool _pumpAgain = false;

  /// Told whenever the snapshot would read differently.
  Stream<void> get changes => _changes.stream;

  /// Registers how tickets of [kind] are started once granted — restored ones
  /// after a restart included — and what a cancel of one undoes.
  /// A kind that is not [restorable] waits in memory only: a restart drops
  /// its tickets.
  void onGranted(
    String kind,
    LaunchDispatch dispatch, {
    void Function(LaunchTicket ticket)? onCancelled,
    bool restorable = true,
  }) => _dispatchers[kind] = (
    dispatch: dispatch,
    cancelled: onCancelled,
    restorable: restorable,
  );

  /// Restores the persisted queue and starts granting. Call once every
  /// dispatcher is registered; a restored ticket of no known kind is dropped.
  void start() {
    if (_started) return;
    _started = true;
    final raw = readQueue?.call();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final entry in list) {
            final ticket = LaunchTicket.fromJson(entry);
            if (ticket == null) continue;
            if (!(_dispatchers[ticket.claim.kind]?.restorable ?? false)) {
              log?.call(
                'Launch queue: dropped ${ticket.id}, no '
                '${ticket.claim.kind} dispatcher',
              );
              continue;
            }
            _queue.add(ticket);
          }
        }
      } on FormatException {
        log?.call('Launch queue: unreadable, starting empty');
      }
    }
    _persist();
    pump();
  }

  /// Grants [claim] now or queues it. [startAnyway] — a person's own,
  /// confirmed — skips every limit and the pause, and counts from then on.
  LaunchAdmission acquire(LaunchClaim claim, {bool startAnyway = false}) {
    _expireReservations();
    if (startAnyway) return LaunchGranted(_reserve(claim));
    final policy = limits();
    final ahead = _ordered()
        .where(
          (t) =>
              claim.priority == LaunchPriority.background ||
              t.claim.priority == LaunchPriority.interactive,
        )
        .toList();
    final counts = _counts(policy);
    for (final ticket in ahead) {
      if (_heldBack(ticket.claim, policy) == null) {
        _add(counts, ticket.claim, policy);
      }
    }
    final blocked = _heldBack(claim, policy) ?? _full(claim, policy, counts);
    if (blocked == null) return LaunchGranted(_reserve(claim));
    final ticket = LaunchTicket(
      id: _newId(),
      claim: claim,
      enqueuedAt: clock.nowUtc(),
    );
    _queue.add(ticket);
    _persist();
    pump();
    final place = _placeOf(ticket.id);
    return LaunchWaiting(
      ticket,
      reason: _reasons[ticket.id] ?? blocked,
      place: place,
    );
  }

  /// Takes [ticketId] out of line without starting it.
  bool cancel(String ticketId) {
    final ticket = _take(ticketId);
    if (ticket == null) return false;
    _dispatchers[ticket.claim.kind]?.cancelled?.call(ticket);
    pump();
    return true;
  }

  /// Starts [ticketId] now, over every limit — a person's confirmed choice.
  bool startAnyway(String ticketId) {
    final ticket = _take(ticketId);
    if (ticket == null) return false;
    _deliver(ticket, _reserve(ticket.claim));
    pump();
    return true;
  }

  LaunchTicket? ticketForSession(String sessionId) {
    for (final ticket in _queue) {
      if (ticket.claim.sessionId == sessionId) return ticket;
    }
    return null;
  }

  /// Grants every waiter that now fits, interactive first and oldest first
  /// within each. A waiter that does not fit keeps its place: what it needs
  /// is counted as taken for everyone behind it, so nobody overtakes it.
  void pump() {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        _pumpOnce();
      } while (_pumpAgain);
    } finally {
      _pumping = false;
    }
    _announce();
  }

  void _pumpOnce() {
    _expireReservations();
    final policy = limits();
    final counts = _counts(policy);
    _reasons.clear();
    for (final ticket in _ordered()) {
      final claim = ticket.claim;
      final held = _heldBack(claim, policy);
      if (held != null) {
        _reasons[ticket.id] = held;
        continue;
      }
      final full = _full(claim, policy, counts);
      if (full == null && _started) {
        _take(ticket.id, persist: false);
        _deliver(ticket, _reserve(claim, pump: false));
        _add(counts, claim, policy);
        continue;
      }
      _reasons[ticket.id] = full ?? 'Waiting for the server to start';
      _add(counts, claim, policy);
    }
    _persist();
  }

  /// What a client and the `capacity` tool show.
  CapacitySnapshot snapshot() {
    final policy = limits();
    final holders = _holders();
    final scopes = <CapacityScopeUse>[];
    void scope(CapacityScope kind, String key, int limit) {
      final mine = holders.where((h) => _matches(h, kind, key)).toList();
      scopes.add(
        CapacityScopeUse(
          scope: kind,
          key: key,
          label: names.of(kind, key),
          used: mine.length,
          limit: limit,
          holders: [for (final h in mine) h.label],
        ),
      );
    }

    if (policy.global case final limit?) scope(CapacityScope.global, '', limit);
    for (final e in policy.machines.entries) {
      scope(CapacityScope.machine, e.key, e.value);
    }
    for (final e in policy.accounts.entries) {
      scope(CapacityScope.account, e.key, e.value);
    }
    for (final e in policy.projects.entries) {
      scope(CapacityScope.project, e.key, e.value);
    }
    final ordered = _ordered();
    return CapacitySnapshot(
      limits: policy,
      running: holders.length,
      scopes: scopes,
      waiters: [
        for (final (i, t) in ordered.indexed)
          LaunchWaiter(
            ticketId: t.id,
            label: t.claim.label,
            sessionId: t.claim.sessionId,
            priority: t.claim.priority,
            place: i + 1,
            reason: _reasons[t.id] ?? 'Waiting for a slot',
            enqueuedAt: t.enqueuedAt,
            personStarted: t.claim.personStarted,
          ),
      ],
    );
  }

  Future<void> dispose() => _changes.close();

  // --- counting ---

  List<SlotHolder> _holders() {
    final live = occupants();
    final ids = {for (final h in live) h.sessionId};
    return [
      ...live,
      for (final r in _reservations)
        if (r.claim.sessionId == null || !ids.contains(r.claim.sessionId))
          SlotHolder(
            sessionId: r.claim.sessionId ?? '',
            label: r.claim.label,
            environmentId: r.claim.environmentId,
            accountKey: r.claim.accountKey,
            projectId: r.claim.projectId,
          ),
    ];
  }

  static bool _matches(SlotHolder h, CapacityScope scope, String key) =>
      switch (scope) {
        CapacityScope.global => true,
        CapacityScope.machine => h.environmentId == key,
        CapacityScope.account => h.accountKey == key,
        CapacityScope.project => h.projectId == key,
      };

  static String _slot(CapacityScope scope, String key) => '${scope.name}:$key';

  static List<(CapacityScope, String)> _scopesOf(
    String environmentId,
    String accountKey,
    String projectId,
  ) => [
    (CapacityScope.machine, environmentId),
    (CapacityScope.account, accountKey),
    (CapacityScope.project, projectId),
    (CapacityScope.global, ''),
  ];

  Map<String, int> _counts(LaunchLimits policy) {
    final counts = <String, int>{};
    for (final h in _holders()) {
      for (final (scope, key) in _scopesOf(
        h.environmentId,
        h.accountKey,
        h.projectId,
      )) {
        if (policy.limitOf(scope, key) == null) continue;
        counts.update(_slot(scope, key), (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return counts;
  }

  void _add(Map<String, int> counts, LaunchClaim c, LaunchLimits policy) {
    for (final (scope, key) in _scopesOf(
      c.environmentId,
      c.accountKey,
      c.projectId,
    )) {
      if (policy.limitOf(scope, key) == null) continue;
      counts.update(_slot(scope, key), (n) => n + 1, ifAbsent: () => 1);
    }
  }

  /// Why [c] cannot start under [counts], or null when every scope has room.
  String? _full(LaunchClaim c, LaunchLimits policy, Map<String, int> counts) {
    for (final (scope, key) in _scopesOf(
      c.environmentId,
      c.accountKey,
      c.projectId,
    )) {
      final limit = policy.limitOf(scope, key);
      if (limit == null) continue;
      if ((counts[_slot(scope, key)] ?? 0) < limit) continue;
      return _fullReason(scope, key, limit);
    }
    return null;
  }

  String _fullReason(CapacityScope scope, String key, int limit) {
    final busy = _holders().where((h) => _matches(h, scope, key)).toList();
    final where = switch (scope) {
      CapacityScope.global => '',
      CapacityScope.machine => ' on ${names.of(scope, key)}',
      CapacityScope.account => ' for ${names.of(scope, key)}',
      CapacityScope.project => ' in ${names.of(scope, key)}',
    };
    final count = busy.length;
    final verb = count == 1 ? 'is' : 'are';
    final ahead = count < limit
        ? ', and ${limit - count} ${limit - count == 1 ? 'is' : 'are'} '
              'promised to launches ahead in line'
        : '';
    final who = busy.isEmpty
        ? ''
        : ' (${busy.map((h) => h.label).take(4).join(', ')}'
              '${busy.length > 4 ? ', …' : ''})';
    return 'Waiting for a slot: $count of $limit$where $verb busy$who$ahead';
  }

  /// A background claim held back by the pause or the usage hold.
  String? _heldBack(LaunchClaim c, LaunchLimits policy) {
    if (c.priority != LaunchPriority.background) return null;
    if (policy.pauseBackground) {
      return 'Waiting: new background work is paused';
    }
    final hold = policy.holdBackgroundAbovePercent;
    if (hold == null) return null;
    final percent = fiveHourPercent?.call(c.accountKey);
    if (percent == null || percent <= hold) return null;
    return 'Waiting: ${names.of(CapacityScope.account, c.accountKey)} is at '
        '${percent.round()}% of its 5-hour window, over the $hold% hold for '
        'background work';
  }

  // --- the queue ---

  List<LaunchTicket> _ordered() {
    int rank(LaunchTicket t) =>
        t.claim.priority == LaunchPriority.interactive ? 0 : 1;
    return [..._queue]..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.enqueuedAt.compareTo(b.enqueuedAt);
    });
  }

  int _placeOf(String ticketId) {
    final ordered = _ordered();
    for (final (i, t) in ordered.indexed) {
      if (t.id == ticketId) return i + 1;
    }
    return 0;
  }

  LaunchTicket? _take(String ticketId, {bool persist = true}) {
    final index = _queue.indexWhere((t) => t.id == ticketId);
    if (index < 0) return null;
    final ticket = _queue.removeAt(index);
    if (persist) _persist();
    return ticket;
  }

  LaunchReservation _reserve(LaunchClaim claim, {bool pump = true}) {
    final reservation = LaunchReservation._(this, claim, clock.nowUtc());
    _reservations.add(reservation);
    if (pump) _announce();
    return reservation;
  }

  void _deliver(LaunchTicket ticket, LaunchReservation reservation) {
    final dispatcher = _dispatchers[ticket.claim.kind];
    if (dispatcher == null) {
      log?.call('Launch queue: nothing starts ${ticket.claim.kind}');
      reservation.release();
      return;
    }
    unawaited(
      Future<void>(() => dispatcher.dispatch(ticket, reservation))
          .catchError((Object error) {
            log?.call('Launch queue: ${ticket.id} did not start: $error');
          })
          .whenComplete(reservation.release),
    );
  }

  void _expireReservations() {
    final cutoff = clock.nowUtc().subtract(reservationTimeout);
    final stale = [
      for (final r in _reservations)
        if (r.takenAt.isBefore(cutoff)) r,
    ];
    for (final r in stale) {
      _reservations.remove(r);
      if (!r._released) {
        r._released = true;
        r._done.complete();
      }
    }
  }

  void _persist() =>
      writeQueue?.call(jsonEncode([for (final t in _queue) t.toJson()]));

  void _announce() {
    if (_changes.isClosed) return;
    final fingerprint = jsonEncode(snapshot().toJson());
    if (fingerprint == _lastFingerprint) return;
    _lastFingerprint = fingerprint;
    _changes.add(null);
  }
}

String Function() _counterId() {
  var next = 0;
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return () => 'launch-$stamp-${next++}';
}
