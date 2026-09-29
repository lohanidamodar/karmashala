import 'dart:async';

import 'package:flutter/material.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairingException;
import 'package:karmashala_ui/tokens.dart';

import '../core/lifecycle/server_switcher.dart';
import '../core/server/machine_pairing.dart';
import '../core/util/failure_words.dart';

/// [NoServer]'s screen: a client with no server of its own pairs with a
/// machine, then opens it. This code and address form stands in until the
/// phone's pairing flow (Stage 1 step 10) replaces it.
class NoServerPairing extends StatefulWidget {
  const NoServerPairing({
    super.key,
    required this.switcher,
    required this.deviceName,
  });

  final ServerSwitcher switcher;

  /// What the server will call this device.
  final String deviceName;

  @override
  State<NoServerPairing> createState() => _NoServerPairingState();
}

class _NoServerPairingState extends State<NoServerPairing> {
  final _code = TextEditingController();
  final _address = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final record = await pairWithMachine(
        store: widget.switcher.machines.store,
        code: _code.text,
        address: _address.text,
        deviceName: widget.deviceName,
      );
      // This tree goes with the switch; nothing here is touched after it.
      unawaited(widget.switcher.switchTo(record));
      return;
    } on CompanionPairingException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Pairing failed: ${describeFailure(error)}');
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        key: const Key('no-server-pairing'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pair this phone with a machine',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: Insets.md),
          const Text(
            'On the machine run `karmashala_host pair --grants desktop` '
            '(add `--address=<its address>` for a code that says where it '
            'is), then paste the code or the payload it printed.',
          ),
          const SizedBox(height: Insets.md),
          TextField(
            key: const Key('no-server-code'),
            controller: _code,
            minLines: 1,
            maxLines: 4,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Code or payload'),
          ),
          const SizedBox(height: Insets.xs),
          TextField(
            key: const Key('no-server-address'),
            controller: _address,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Address (host:port), if the code names none',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Insets.sm),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: Insets.lg),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('no-server-pair'),
              onPressed: _busy ? null : _pair,
              child: Text(_busy ? 'Pairing…' : 'Pair'),
            ),
          ),
        ],
      ),
    );
  }
}
