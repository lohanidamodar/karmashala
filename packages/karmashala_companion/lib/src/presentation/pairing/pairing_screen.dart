import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import '../companion_chrome.dart';
import '../companion_route.dart';
import '../companion_states.dart';
import 'add_machine_screen.dart';
import 'scan_qr_screen.dart';
import 'short_code_screen.dart';

/// What an unpaired companion shows: why there is nothing here, and the two
/// ways in. A [CompanionNotice], the same shape as every other "nothing here
/// yet" screen, rather than its own hand-picked glyph size and body step.
class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Also pushed from "Add a machine" — Settings and the host switcher — where
    // it needs the way back a root does not have.
    final pushed = Navigator.of(context).canPop();
    return Scaffold(
      appBar: pushed
          ? companionAppBar(context, title: const Text('Add a machine'))
          : null,
      body: SafeArea(
        child: CompanionNotice(
          icon: AppIcons.deviceMobile,
          title: 'Pair with a machine',
          body:
              'This phone is a remote for the sessions a machine holds: a '
              'computer running the desktop app, or a Karmashala server. In '
              'the desktop app choose Settings → Remote and pairing → '
              '"Pair a device"; on a server run karmashala_host pair. Then scan its '
              'QR code, or paste its code.',
          actionLabel: 'Scan the QR code',
          onAction: () => Navigator.of(
            context,
          ).push(companionRoute<void>(context, (_) => const ScanQrScreen())),
          secondaryLabel: 'Paste the code instead',
          onSecondary: () => Navigator.of(
            context,
          ).push(companionRoute<void>(context, (_) => const ShortCodeScreen())),
          // A box is never found by searching, so it gets its own way in
          // rather than a code field that quietly does not work for it.
          tertiaryLabel: 'Add a machine by address',
          onTertiary: () => Navigator.of(context).push(
            companionRoute<void>(context, (_) => const AddMachineScreen()),
          ),
        ),
      ),
    );
  }
}
