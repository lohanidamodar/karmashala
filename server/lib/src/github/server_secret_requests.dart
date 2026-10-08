import 'dart:async';
import 'dart:math';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;

import 'owner_only_file.dart';

/// What answers a client's secret-request work.
abstract interface class SecretWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(SecretRequestWork<Object?> request);
}

/// How an agent's request for a secret ended.
sealed class SecretOutcome {
  const SecretOutcome();
}

/// The owner saved a value; the agent is given only [reference].
final class SecretProvided extends SecretOutcome {
  const SecretProvided(this.reference);

  final String reference;
}

final class SecretDeclined extends SecretOutcome {
  const SecretDeclined();
}

final class SecretUnanswered extends SecretOutcome {
  const SecretUnanswered();
}

/// The prefix every reference starts with, so a tool can tell one at sight.
const String kSecretReferencePrefix = 'ks-secret:';

/// The longest secret accepted.
const int kMaxSecretLength = 8192;

/// Agents' requests for a secret, shown to the owner as a private card, and
/// the values the owner saved in `<data>/secrets/agent-secrets.json`. An
/// agent is answered with a single-use reference; a value leaves only through
/// [redeem], to the server's own work, once.
class ServerSecretRequests implements SecretWork {
  ServerSecretRequests({
    required String dataDirectory,
    required void Function(List<DataChange> changes) tell,
    DateTime Function()? now,
    String Function()? newId,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
  }) : _tell = tell,
       _now = now ?? _utcNow,
       _newId = newId ?? _randomId,
       _file = OwnerOnlyJsonFile(
         dataDirectory: dataDirectory,
         fileName: fileName,
         what: 'the agent secret store',
         permissions: permissions,
       ) {
    _load();
  }

  static const String fileName = 'agent-secrets.json';

  final void Function(List<DataChange> changes) _tell;
  final DateTime Function() _now;
  final String Function() _newId;
  final OwnerOnlyJsonFile _file;

  final Map<String, ({SecretRequest request, Completer<SecretOutcome> done})>
  _pending = {};

  /// Reference → the saved value.
  final Map<String, ({String value, DateTime savedAt})> _saved = {};

  static DateTime _utcNow() => DateTime.now().toUtc();

  static final Random _random = Random.secure();

  static String _randomId() => [
    for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16),
  ].map((b) => b.padLeft(2, '0')).join();

  /// The requests waiting for the owner, oldest first.
  List<SecretRequest> get pending => [
    for (final entry in _pending.values) entry.request,
  ];

  List<DataChange> greeting() => [SecretRequestsChanged(pending)];

  /// Asks the owner for a secret for [sessionId]'s agent and waits up to
  /// [timeout] for the answer.
  Future<SecretOutcome> request({
    required String sessionId,
    required String label,
    required String reason,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final asked = SecretRequest(
      id: _newId(),
      sessionId: sessionId,
      label: label,
      reason: reason,
      requestedAt: _now(),
    );
    final done = Completer<SecretOutcome>();
    _pending[asked.id] = (request: asked, done: done);
    _announce();
    try {
      return await done.future.timeout(
        timeout,
        onTimeout: () => const SecretUnanswered(),
      );
    } finally {
      if (_pending.remove(asked.id) != null) _announce();
    }
  }

  /// [reference]'s value, once: the reference is spent by this call.
  Future<String?> redeem(String reference) async {
    final saved = _saved.remove(reference.trim());
    if (saved == null) return null;
    try {
      await _write();
    } on Object {
      _saved[reference.trim()] = saved;
      rethrow;
    }
    return saved.value;
  }

  @override
  Future<Object?> handle(SecretRequestWork<Object?> request) async =>
      switch (request) {
        SecretRequestsRead() => pending,
        SecretProvide(:final id, :final value) => await _provide(id, value),
        SecretDecline(:final id) => _decline(id),
      };

  ({SecretRequest request, Completer<SecretOutcome> done}) _waiting(
    String id,
  ) =>
      _pending[id] ??
      (throw DataRefused.notFound(
        'That request is no longer waiting: it was answered or timed out.',
      ));

  Future<DataAck> _provide(String id, String value) async {
    final waiting = _waiting(id);
    if (value.isEmpty) throw DataRefused.invalid('Enter the secret to save.');
    if (value.length > kMaxSecretLength) {
      throw DataRefused.invalid('That secret is too long to keep.');
    }
    final reference = '$kSecretReferencePrefix${_randomId()}';
    _saved[reference] = (value: value, savedAt: _now());
    try {
      await _write();
    } on Object {
      _saved.remove(reference);
      rethrow;
    }
    _pending.remove(id);
    _announce();
    if (!waiting.done.isCompleted) {
      waiting.done.complete(SecretProvided(reference));
    }
    return const DataAck();
  }

  DataAck _decline(String id) {
    final waiting = _waiting(id);
    _pending.remove(id);
    _announce();
    if (!waiting.done.isCompleted) {
      waiting.done.complete(const SecretDeclined());
    }
    return const DataAck();
  }

  void _announce() => _tell([SecretRequestsChanged(pending)]);

  void _load() {
    final saved = _file.read()['secrets'];
    if (saved is! Map) return;
    for (final MapEntry(:key, :value) in saved.entries) {
      if (value is! Map || value['value'] is! String) continue;
      _saved['$key'] = (
        value: value['value'] as String,
        savedAt:
            DateTime.tryParse('${value['savedAt']}')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    }
  }

  Future<void> _write() => _file.write({
    'version': 1,
    'secrets': {
      for (final MapEntry(:key, :value) in _saved.entries)
        key: {'value': value.value, 'savedAt': value.savedAt.toIso8601String()},
    },
  });
}
