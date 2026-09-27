import 'dart:async';
import 'package:karmashala_host_protocol/host_access.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host_protocol/protocol.dart';

import 'host_deploy_target.dart';

/// Asks a host that is already serving to open a pairing window.
///
/// The ceremony has to start on the host — it is the peer the phone pairs with,
/// and only `serve` holds the listener the phone's link will arrive on. This is
/// the desktop asking, over the channel it already uses to deploy and greet.
class RemotePairing {
  RemotePairing({
    required this.target,
    required this.remotePath,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
    AppLogger? logger,
  }) : _now = clock ?? DateTime.now,
       _logger = logger ?? AppLogger.named('ssh.pairing');

  final HostDeployTarget target;

  /// The executable `HostDeployment.remotePath` named. The same one a pane
  /// runs, so this cannot end up talking to a different host than the sessions.
  final String remotePath;

  final Duration timeout;
  final DateTime Function() _now;
  final AppLogger _logger;

  /// Opens a window and answers what to type. [capabilities] is the grant the
  /// person chose — passed through untouched, because a desktop that widened it
  /// would be granting what nobody offered.
  Future<PairingWindow> open({
    required int capabilities,
    String relay = '',
  }) async {
    RemoteChannel? channel;
    try {
      channel = await target.exec('$remotePath attach');
      final parser = FrameParser();
      final answer = Completer<PairingWindow>();

      final subscription = channel.stdout.listen((chunk) {
        if (answer.isCompleted) return;
        try {
          for (final frame in parser.add(chunk)) {
            final message = decodeMessage(frame);
            if (message is PairedMessage) {
              answer.complete(
                PairingWindow(
                  status: PairingRequestStatus.open,
                  observedAt: _now(),
                  reason: 'Type this into the phone before it expires.',
                  code: message.code,
                  expiresAt: message.expiresAt,
                ),
              );
              return;
            }
            if (message is ErrorMessage) {
              answer.complete(_refusal(message));
              return;
            }
          }
        } on Object catch (error) {
          if (!answer.isCompleted) answer.completeError(error);
        }
      }, onError: (Object _) {});

      // Hello first: the host refuses anything else as its opening frame, and
      // the version check it does there is the one that catches a skewed pair.
      channel
        ..add(
          const HelloMessage(
            requestId: 1,
            clientId: 'karmashala-pairing',
          ).toFrame().encode(),
        )
        ..add(
          PairMessage(
            requestId: 2,
            capabilities: capabilities,
            relay: relay,
          ).toFrame().encode(),
        );

      try {
        return await answer.future.timeout(timeout);
      } finally {
        await subscription.cancel();
      }
    } on TimeoutException {
      return PairingWindow(
        status: PairingRequestStatus.noAnswer,
        observedAt: _now(),
        reason:
            'The host on ${target.address} did not answer within '
            '${timeout.inSeconds}s. Nothing was opened, so nothing expires.',
      );
    } on Object catch (error) {
      _logger.debug('pairing on ${target.address} failed: $error');
      return PairingWindow(
        status: PairingRequestStatus.noAnswer,
        observedAt: _now(),
        reason: 'Could not ask the host on ${target.address} to pair ($error).',
      );
    } finally {
      await channel?.close();
    }
  }

  /// A host that refused, and which of the two kinds it is.
  ///
  /// **Told apart by the request id, not by the words.** A host older than
  /// pairing fails at *frame parsing* — `unknown message type 0x12` — and so
  /// answers with id 0, because it never read one. A host that understood the
  /// request and cannot serve it echoes the id back. Both are `badRequest`, so
  /// the code alone cannot separate them, and matching the prose would make
  /// this break the next time somebody improves a sentence.
  PairingWindow _refusal(ErrorMessage message) {
    final tooOld = message.requestId == 0;
    return PairingWindow(
      status: tooOld
          ? PairingRequestStatus.hostTooOld
          : PairingRequestStatus.hostCannotPair,
      observedAt: _now(),
      reason: tooOld
          ? 'The host on ${target.address} is older than pairing. Deploy again '
                'and stop the running `serve` so the new one takes over.'
          : 'The host on ${target.address} refused: ${message.message}',
    );
  }
}
