import 'package:flutter/material.dart';

import '../../verification/presentation/verification_pane.dart';

/// The verification runs, as a shell surface.
///
/// The same thin wrapper `RepositoryInfoView` is: the shell mounts *this*, and
/// the feature keeps its widgets to itself. Wiring it up is two lines in
/// `app/shell` — a `verification` value on `SidePanelSurface` and
/// `SidePanelSurface.verification => const VerificationView()` in
/// `_surfaceBody` — which this loop deliberately did not write, because
/// `app/shell/**` belonged to another agent while it ran. Everything else the
/// surface needs is here.
class VerificationView extends StatelessWidget {
  const VerificationView({super.key});

  @override
  Widget build(BuildContext context) => const VerificationPane();
}
