import 'package:flutter/material.dart';

import '../../../../app/theme/app_icons.dart';
import '../companion_chrome.dart';
import '../companion_states.dart';
import 'scan_qr_screen.dart';
import 'short_code_screen.dart';

/// What an unpaired companion shows: why there is nothing here, and the two
/// ways in (scan the desktop's QR code, or type its short code).
///
/// Drawn as a [CompanionNotice] rather than as its own arrangement of an icon,
/// a heading and two buttons. It is the same shape as every other "there is
/// nothing here yet, and here is what to do about it" screen in the app, and
/// it is the *first* one anybody sees — so it is the last place that should
/// have its own hand-picked glyph size and its own body step.
class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Shown as the root of an unpaired phone, and pushed from Settings' "Add a
    // desktop". The pushed one needs the way back a root does not have: the
    // system gesture worked, but nothing on screen said so.
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
