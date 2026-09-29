import 'dart:async';

import 'package:flutter/material.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/lifecycle/server_switcher.dart';
import '../../../core/server/machine_pairing.dart';
import '../../../core/server/machines.dart';
import '../../../core/util/failure_words.dart';
import 'pair_machine_forms.dart';
import 'pair_machine_scan.dart';

/// One pairing attempt, the same for all three ways in: [pairWithMachine]
/// into [machines], then [onPaired] with the record. Holds no provider, so
/// [NoServer]'s screen, where no container is open, can use it.
class MachinePairer {
  const MachinePairer({
    required this.machines,
    required this.client,
    required this.onPaired,
  });

  final Machines machines;
  final ClientCapabilities client;

  /// Opens the machine just paired (a switch, in process).
  final void Function(CompanionPairing record) onPaired;

  /// Pairs [code] (reached at [address], if given); the refusal in words.
  Future<String?> pair({required String code, String? address}) async {
    final CompanionPairing record;
    try {
      record = await pairWithMachine(
        store: machines.store,
        code: code,
        address: address,
        deviceName: client.deviceName,
        hostsServer: client.hostsServer,
      );
    } on CompanionPairingException catch (error) {
      return error.message;
    } on Object catch (error) {
      return 'Pairing failed: ${describeFailure(error)}';
    }
    onPaired(record);
    return null;
  }
}

/// Pairing on a phone (Stage 1 step 10): scan the QR, paste the code, or add
/// a machine by address — the companion's three ways in, all through
/// [pairWithMachine]. [NoServer]'s screen, and the phone's "Add a machine".
class PairMachinePage extends StatelessWidget {
  const PairMachinePage({super.key, required this.pairer, this.title});

  final MachinePairer pairer;

  /// Shown above the choices; null where the route's app bar says it.
  final String? title;

  /// The machines list's "Add a machine" on a client that cannot host: the
  /// page as a route, and a pairing then switches this app to that machine.
  static Future<void> push(
    BuildContext context, {
    required Machines machines,
    required ClientCapabilities client,
    required ServerSwitcher? switcher,
    VoidCallback? onListChanged,
  }) {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final base = ModalRoute.of(context);
    Future<void> paired(CompanionPairing record) async {
      navigator.popUntil((route) => route == base || route.isFirst);
      onListChanged?.call();
      final outcome = await switcher?.switchTo(record);
      if (outcome == ServerSwitchOutcome.busy ||
          outcome == ServerSwitchOutcome.kept) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              '${serverNameForSwitch(record)} is paired. Switch to it from '
              'the machines list.',
            ),
          ),
        );
      }
    }

    return navigator.push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Add a machine')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Padding(
                  padding: const EdgeInsets.all(Insets.xl),
                  child: PairMachinePage(
                    pairer: MachinePairer(
                      machines: machines,
                      client: client,
                      onPaired: (record) => unawaited(paired(record)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void open(Widget page) => unawaited(
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
    );
    return SingleChildScrollView(
      child: Column(
        key: const Key('pair-machine'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(title!, style: theme.textTheme.titleLarge),
            const SizedBox(height: Insets.md),
          ],
          Text(
            'On the machine, open Settings → Remote → "Pair a phone", or run '
            '`karmashala_host pair` on a server. Then:',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          FilledButton.icon(
            key: const Key('pair-machine-scan'),
            icon: const Icon(AppIcons.qrCode),
            label: const Text('Scan the QR code'),
            onPressed: () => open(PairMachineScanScreen(pairer: pairer)),
          ),
          const SizedBox(height: Insets.sm),
          OutlinedButton.icon(
            key: const Key('pair-machine-paste'),
            icon: const Icon(AppIcons.clipboardText),
            label: const Text('Paste the code instead'),
            onPressed: () => open(
              PairMachineCodeScreen(pairer: pairer, byAddress: false),
            ),
          ),
          const SizedBox(height: Insets.sm),
          OutlinedButton.icon(
            key: const Key('pair-machine-address'),
            icon: const Icon(AppIcons.globe),
            label: const Text('Add a machine by address'),
            onPressed: () => open(
              PairMachineCodeScreen(pairer: pairer, byAddress: true),
            ),
          ),
        ],
      ),
    );
  }
}
