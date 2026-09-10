import 'package:flutter/material.dart';

import '../../verification/presentation/verification_pane.dart';

/// The verification runs, as a shell surface — the same thin wrapper
/// `RepositoryInfoView` is: the shell mounts this, the feature keeps its widgets.
class VerificationView extends StatelessWidget {
  const VerificationView({super.key});

  @override
  Widget build(BuildContext context) => const VerificationPane();
}
