import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import 'ssh_connection_state.dart';
import 'ssh_host.dart';
import 'ssh_host_key.dart';
import 'channel_limiter.dart';
import 'resilient_ssh_socket.dart';
import 'ssh_host_key_verifier.dart';

/// Asked for a password or a key passphrase. Returning `null` aborts the
/// connection; whatever is returned is used once and never written anywhere.
typedef SshSecretPrompt = FutureOr<String?> Function(SshHost host);

/// Reads a private key file. Injected so tests never touch the filesystem and
/// so a future key store can replace the default without changing callers.
typedef PrivateKeyReader = Future<String> Function(EnvironmentPath path);

/// Raised when a connection cannot be established or has been lost. [cause]
/// tells a refused host key ([HostKeyRejected]) from a bad credential.
class SshConnectionException implements Exception {
  SshConnectionException(this.message, {this.cause, this.retryable = false});

  final String message;
  final Object? cause;

  /// Whether retrying could plausibly help (network) or not (host key, auth).
  final bool retryable;

  @override
  String toString() =>
      'SshConnectionException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Reads a private key from the local filesystem. Refuses a remote path: a key
/// fetched over the connection it authenticates is not a key we can use.
Future<String> readLocalPrivateKey(EnvironmentPath path) async {
  if (path.environmentId.startsWith('ssh:')) {
    throw SshConnectionException(
      'Private key ${path.path} is recorded in remote environment '
      '${path.environmentId}; it must live on a local environment.',
    );
  }
  final file = File(path.path);
  if (!await file.exists()) {
    throw SshConnectionException('Private key not found: ${path.path}');
  }
  return file.readAsString();
}

/// One live SSH connection to one [SshHost]. [client] is the only way in — it
/// reconnects with backoff and throws rather than hand back a dead session.
class SshConnection {
  SshConnection({
    required this.host,
    required this.verifier,
    this.passwordPrompt,
    this.passphrasePrompt,
    this.keyReader = readLocalPrivateKey,
    this.connectTimeout = const Duration(seconds: 15),
    this.maxAttempts = 3,
    int maxConcurrentCommands = 4,
    this.channelOpenAttempts = 4,
    AppLogger? logger,
  }) : _commandSlots = ChannelLimiter(maxConcurrentCommands),
       _logger = logger ?? AppLogger.named('ssh.connection');

  final SshHost host;
  final SshHostKeyVerifier verifier;
  final SshSecretPrompt? passwordPrompt;
  final SshSecretPrompt? passphrasePrompt;
  final PrivateKeyReader keyReader;
  final Duration connectTimeout;

  /// How many attempts one [client] call makes before giving up, with
  /// [reconnectBackoff] between them.
  final int maxAttempts;

  /// How many times a refused channel open is retried: a server frees a
  /// finished session slightly late, so a burst can briefly exceed its limit.
  final int channelOpenAttempts;

  final ChannelLimiter _commandSlots;
  final AppLogger _logger;

  final StreamController<SshConnectionState> _states =
      StreamController<SshConnectionState>.broadcast();

  SSHClient? _client;
  Future<SSHClient>? _connecting;
  bool _closed = false;
  SshConnectionState _state = const SshConnectionState.idle();

  /// The current lifecycle state.
  SshConnectionState get state => _state;

  /// Lifecycle transitions, for the UI and for logs.
  Stream<SshConnectionState> get states => _states.stream;

  /// Whether a usable session is open right now.
  bool get isConnected => _client != null && !_client!.isClosed;

  /// The live session, connecting or reconnecting as needed. Throws
  /// [SshConnectionException] rather than ever return a closed session.
  Future<SSHClient> client() {
    if (_closed) {
      throw SshConnectionException('Connection to ${host.address} is closed.');
    }
    final existing = _client;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    return _connecting ??= _connectWithRetries().whenComplete(() {
      _connecting = null;
    });
  }

  /// Runs [body] holding one channel slot, so a wide fan-out queues instead of
  /// exhausting the server. Streaming sessions skip it: queuing would deadlock.
  Future<T> runOnChannel<T>(Future<T> Function(SSHClient client) body) =>
      _commandSlots.withSlot(() => _withChannelRetry(body));

  /// Retries [body] when the *channel open* is refused — safe because a refused
  /// open means nothing ran: `dartssh2` reports it before the command is sent.
  Future<T> _withChannelRetry<T>(
    Future<T> Function(SSHClient client) body,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await body(await client());
      } on SSHChannelOpenError catch (e) {
        if (attempt >= channelOpenAttempts) rethrow;
        final wait = Duration(milliseconds: 25 << attempt);
        _logger.debug(
          '${host.address} refused a channel ($e); retrying in '
          '${wait.inMilliseconds} ms.',
        );
        await Future<void>.delayed(wait);
      }
    }
  }

  /// How many command channels are open right now, and how many are queued.
  (int inUse, int waiting) get channelPressure =>
      (_commandSlots.inUse, _commandSlots.waiting);

  /// Drops the current session so the next [client] call reconnects. Used by a
  /// manual "reconnect" action and by tests.
  Future<void> reset() async {
    final current = _client;
    _client = null;
    if (current != null && !current.isClosed) await current.close();
    _emit(const SshConnectionState(status: SshConnectionStatus.disconnected));
  }

  /// Closes the connection permanently.
  Future<void> close() async {
    _closed = true;
    final current = _client;
    _client = null;
    if (current != null && !current.isClosed) await current.close();
    await _states.close();
  }

  Future<SSHClient> _connectWithRetries() async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        final wait = reconnectBackoff(attempt - 1);
        _emit(
          SshConnectionState(
            status: SshConnectionStatus.disconnected,
            error: _describe(lastError),
            attempt: attempt - 1,
            nextRetryIn: wait,
          ),
        );
        await Future<void>.delayed(wait);
        if (_closed) break;
      }
      _emit(
        SshConnectionState(
          status: SshConnectionStatus.connecting,
          attempt: attempt - 1,
        ),
      );
      try {
        final client = await _connectOnce();
        if (_closed) {
          // Closed while the dial was in flight: nothing may keep this client.
          client.close();
          throw SshConnectionException('Connection closed while connecting', retryable: false);
        }
        _client = client;
        _emit(const SshConnectionState(status: SshConnectionStatus.connected));
        _logger.info('Connected to ${host.address}.');
        return client;
      } on SshConnectionException catch (e) {
        lastError = e;
        if (!e.retryable) {
          _fail(e);
          rethrow;
        }
        _logger.warning(
          'Attempt $attempt to reach ${host.address} failed: ${e.message}',
        );
      }
    }
    final failure = SshConnectionException(
      'Could not connect to ${host.address} after $maxAttempts attempts: '
      '${_describe(lastError)}',
      cause: lastError,
      retryable: true,
    );
    _fail(failure);
    throw failure;
  }

  Future<SSHClient> _connectOnce() async {
    // Credentials are resolved before the socket is opened: a missing key is a
    // configuration error, and it must not leave a socket it cannot use.
    final identities = await _identities();

    final SSHSocket socket;
    try {
      socket = ResilientSshSocket(
        await SSHSocket.connect(host.host, host.port, timeout: connectTimeout),
      );
    } on Object catch (e) {
      throw SshConnectionException(
        'Cannot reach ${host.host}:${host.port}',
        cause: e,
        retryable: true,
      );
    }
    final client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onVerifyHostKey: verifier.verify,
      onPasswordRequest: host.authMethod == SshAuthMethod.password
          ? () => _ask(passwordPrompt, 'password')
          : null,
      handshakeTimeout: connectTimeout,
      authTimeout: connectTimeout,
    );
    // Listened to immediately, not after authentication: a failed auth also
    // completes `done`, and with nobody listening that is an unhandled error.
    unawaited(
      client.done.then(
        (_) => _handleDropped(client, null),
        onError: (Object e) => _handleDropped(client, e),
      ),
    );

    try {
      await client.authenticated;
    } on Object catch (e) {
      client.close();
      // A refused host key surfaces from dartssh2 as a handshake/auth abort, so
      // the verifier's own verdict is the accurate story to tell.
      final presentation = verifier.lastPresentation;
      if (presentation != null &&
          presentation.verdict != HostKeyVerdict.trusted) {
        final rejection = HostKeyRejected(presentation);
        throw SshConnectionException(presentation.describe(), cause: rejection);
      }
      if (e is SSHAuthFailError) {
        throw SshConnectionException(
          'Authentication as ${host.username}@${host.host} was rejected.',
          cause: e,
        );
      }
      throw SshConnectionException(
        'Handshake with ${host.address} failed',
        cause: e,
        retryable: true,
      );
    }
    return client;
  }

  Future<List<SSHKeyPair>?> _identities() async {
    if (host.authMethod != SshAuthMethod.privateKey) return null;
    final keyPath = host.privateKey;
    if (keyPath == null) {
      throw SshConnectionException(
        '${host.name} uses key authentication but has no private key path.',
      );
    }
    final String pem;
    try {
      pem = await keyReader(keyPath);
    } on SshConnectionException {
      rethrow;
    } on Object catch (e) {
      throw SshConnectionException(
        'Could not read the private key for ${host.name}',
        cause: e,
      );
    }

    final bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } on Object catch (e) {
      throw _undecodableKey(e);
    }

    String? passphrase;
    if (encrypted) {
      passphrase = await _ask(passphrasePrompt, 'key passphrase');
    }
    try {
      return SSHKeyPair.fromPem(pem, passphrase);
    } on SshConnectionException {
      rethrow;
    } on Object catch (e) {
      throw _undecodableKey(e);
    }
  }

  /// Reports an unusable key by the *type* of the failure only: a decoder's
  /// message can quote the bytes it choked on, and those are key material.
  SshConnectionException _undecodableKey(Object error) =>
      SshConnectionException(
        'The private key for ${host.name} could not be decoded '
        '(${error.runtimeType}). A wrong passphrase looks like this.',
      );

  Future<String> _ask(SshSecretPrompt? prompt, String what) async {
    if (prompt == null) {
      throw SshConnectionException(
        '${host.address} needs a $what and nothing is available to ask for it.',
      );
    }
    final value = await prompt(host);
    if (value == null) {
      throw SshConnectionException('No $what supplied for ${host.address}.');
    }
    return value;
  }

  void _handleDropped(SSHClient client, Object? error) {
    // Only the session that is actually in use reports a drop: one that never
    // authenticated, or one already replaced by a reconnect, is not news.
    if (!identical(_client, client)) return;
    _client = null;
    if (_closed) return;
    _emit(
      SshConnectionState(
        status: SshConnectionStatus.disconnected,
        error: error == null
            ? 'The remote host closed the connection.'
            : _describe(error),
      ),
    );
    _logger.warning(
      'Connection to ${host.address} dropped'
      '${error == null ? '.' : ': ${_describe(error)}'}',
    );
  }

  void _fail(SshConnectionException e) {
    _emit(
      SshConnectionState(status: SshConnectionStatus.failed, error: e.message),
    );
    _logger.error('Connection to ${host.address} failed: ${e.message}');
  }

  void _emit(SshConnectionState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  static String _describe(Object? error) => switch (error) {
    null => 'unknown error',
    SshConnectionException e => e.message,
    SocketException e => e.message.isEmpty ? 'socket error' : e.message,
    _ => error.toString(),
  };
}
