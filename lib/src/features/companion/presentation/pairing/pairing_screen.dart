import 'package:flutter/material.dart';

import '../../../../app/theme/app_icons.dart';
import '../companion_chrome.dart';
import '../companion_states.dart';
import 'scan_qr_screen.dart';
import 'short_code_screen.dart';

/// What an unpaired companion shows: why there is nothing here, and the two
/// ways in. A [CompanionNotice], the same shape as every other "nothing here
/// yet" screen, rather than its own hand-picked glyph size and body step.
class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Also pushed from Settings' "Add a desktop", where it needs the way back a
    // root does not have.
    final pushed = Navigator.of(context).canPop();
    return Scaffold(
      appBar: pushed
          ? companionAppBar(context, title: const Text('Add a desktop'))
          : null,
      body: SafeArea(
        child: CompanionNotice(
          icon: AppIcons.deviceMobile,
          title: 'Pair with your desktop',
          body:
              'This phone is a remote for the sessions your desktop holds. '
              'On the desktop, open Settings → Remote access and choose '
              '"Pair a device" — scan its QR code, or copy its pairing code '
              'and paste it here.',
          actionLabel: 'Scan the QR code',
          onAction: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const ScanQrScreen())),
          secondaryLabel: 'Paste the code instead',
          onSecondary: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ShortCodeScreen()),
          ),
        ),
      ),
    );
  }
}
