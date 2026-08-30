import 'package:flutter/material.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/design_tokens.dart';
import 'scan_qr_screen.dart';
import 'short_code_screen.dart';

/// What an unpaired companion shows: why there is nothing here, and the two
/// ways in (scan the desktop's QR code, or type its short code).
class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Insets.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    AppIcons.deviceMobile,
                    size: 40,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: Insets.lg),
                  Text(
                    'Pair with your desktop',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: Insets.sm),
                  Text(
                    'This phone is a remote for the sessions your desktop '
                    'holds. On the desktop, open Settings → Remote access '
                    'and choose "Pair a device" — it shows a QR code and a '
                    'short code.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: Insets.xl),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ScanQrScreen(),
                      ),
                    ),
                    icon: const Icon(AppIcons.target, size: 18),
                    label: const Text('Scan the QR code'),
                  ),
                  const SizedBox(height: Insets.sm),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ShortCodeScreen(),
                      ),
                    ),
                    child: const Text('Type the code instead'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
