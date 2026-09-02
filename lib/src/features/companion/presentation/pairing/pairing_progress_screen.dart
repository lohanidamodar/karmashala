import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/design_tokens.dart';
import '../../../remote/protocol.dart';
import '../../client/companion_gateway.dart';
import '../companion_chrome.dart';

/// The moment a QR is decoded or a code submitted, the camera/input screen
/// pushes this: staged, readable progress — code accepted, looking for the
/// desktop (LAN / relay), proving keys, paired — with distinct failure states,
/// a Retry that re-runs the same attempt, and a Back that returns cleanly.
class PairingProgressScreen extends ConsumerStatefulWidget {
  const PairingProgressScreen({required this.attempt, super.key});

  /// One pairing attempt against the gateway — `pairWithQr` with the scanned
  /// payload, or `pairWithCode` with the typed text. Re-run by Retry.
  final Future<CompanionPairing> Function(CompanionGateway gateway) attempt;

  @override
  ConsumerState<PairingProgressScreen> createState() =>
      _PairingProgressScreenState();
}

class _PairingProgressScreenState extends ConsumerState<PairingProgressScreen> {
  CompanionPairingStage _stage = CompanionPairingStage.codeAccepted;
  String? _detail;
  String? _hostName;
  CapabilitySet? _capabilities;
  String? _error;

  StreamSubscription<CompanionPairingProgress>? _updates;

  /// Ignores stragglers from a superseded attempt after a Retry.
  int _attemptSerial = 0;

  @override
  void initState() {
    super.initState();
    // Subscribe before the attempt starts so no stage is missed; start the
    // attempt off the build phase so its first events may setState.
    _updates = ref
        .read(companionGatewayProvider)
        .pairingProgress
        .listen(_onProgress);
    unawaited(Future<void>.microtask(_run));
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  void _onProgress(CompanionPairingProgress progress) {
    if (!mounted) return;
    setState(() {
      _stage = progress.stage;
      _detail = progress.detail ?? _detail;
      _hostName = progress.hostName ?? _hostName;
      _capabilities = progress.capabilities ?? _capabilities;
      if (progress.stage == CompanionPairingStage.failed) {
        _error = progress.message ?? _error;
      }
    });
  }

  Future<void> _run() async {
    final serial = ++_attemptSerial;
    setState(() {
      _stage = CompanionPairingStage.codeAccepted;
      _detail = null;
      _hostName = null;
      _capabilities = null;
      _error = null;
    });
    try {
      final paired = await widget.attempt(ref.read(companionGatewayProvider));
      if (!mounted || serial != _attemptSerial) return;
      setState(() {
        _stage = CompanionPairingStage.paired;
        _hostName = paired.hostName ?? _hostName;
        _capabilities = paired.capabilities;
      });
    } on GatewayException catch (error) {
      // PairingException included — both carry a user-fit sentence.
      if (!mounted || serial != _attemptSerial) return;
      setState(() {
        _stage = CompanionPairingStage.failed;
        _error = error.message;
      });
    } on Object catch (error) {
      if (!mounted || serial != _attemptSerial) return;
      setState(() {
        _stage = CompanionPairingStage.failed;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = _stage == CompanionPairingStage.failed;
    final paired = _stage == CompanionPairingStage.paired;
    return Scaffold(
      appBar: companionAppBar(context, title: const Text('Pairing')),
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
                  for (final step in _steps()) _stepRow(theme, step),
                  if (failed) ...[
                    const SizedBox(height: Insets.lg),
                    Container(
                      padding: const EdgeInsets.all(Insets.lg),
                      decoration: BoxDecoration(
                        // The same tint-plus-words the link banner uses: the
                        // sentence carries the meaning at full contrast and
                        // the colour only supports it.
                        color: SemanticColors.of(
                          context,
                        ).failure.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Text(
                        _error ?? 'Pairing failed.',
                        // What went wrong is the only thing on this screen
                        // worth reading once it appears, so it is set as prose
                        // rather than as a caption.
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                    FilledButton.icon(
                      onPressed: _run,
                      // Unsized: the touch theme gives every button glyph
                      // Touch.icon, and a hand-picked 16 undercut it.
                      icon: const Icon(AppIcons.arrowsClockwise),
                      label: const Text('Retry'),
                    ),
                    const SizedBox(height: Insets.sm),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back'),
                    ),
                  ],
                  if (paired) ...[
                    const SizedBox(height: Insets.lg),
                    FilledButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).popUntil((route) => route.isFirst),
                      child: const Text('Start using this phone'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The four stages as display rows, current state folded in.
  List<_Step> _steps() {
    final grants = _capabilities?.granted
        .map((c) => c.wire.replaceAll('_', ' '))
        .join(', ');
    return [
      const _Step(CompanionPairingStage.codeAccepted, 'Code accepted', null),
      _Step(
        CompanionPairingStage.searching,
        'Looking for your desktop',
        _detail,
      ),
      const _Step(CompanionPairingStage.proving, 'Proving keys', null),
      _Step(
        CompanionPairingStage.paired,
        'Paired with ${_hostName ?? 'your desktop'}',
        grants == null ? null : 'This phone may: $grants',
      ),
    ];
  }

  Widget _stepRow(ThemeData theme, _Step step) {
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    // One step of a four-step rail: big enough to read as a state mark, and
    // the same size whichever of the four states it is in.
    final mark = density.icon + 2;
    final failed = _stage == CompanionPairingStage.failed;
    // Where the attempt stopped: on failure the current stage index is where
    // it died, and that row wears the warning.
    final activeIndex = failed ? _failurePoint().index : _stage.index;
    final done = _stage == CompanionPairingStage.paired
        ? step.stage.index <= activeIndex
        : step.stage.index < activeIndex;
    final active = !done && step.stage.index == activeIndex;

    final (Widget icon, Color colour) = done
        ? (
            Icon(AppIcons.checkCircle, size: mark, color: semantic.idle),
            scheme.onSurface,
          )
        : active && failed
        ? (
            Icon(AppIcons.warning, size: mark, color: semantic.failure),
            semantic.failure,
          )
        : active
        ? (
            SizedBox.square(
              dimension: density.icon,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
            scheme.onSurface,
          )
        : (
            Icon(AppIcons.circle, size: mark, color: scheme.outlineVariant),
            scheme.onSurfaceVariant,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: Insets.xl,
            child: Center(child: icon),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colour,
                    fontWeight: active || done ? FontWeight.w600 : null,
                  ),
                ),
                if (step.detail != null && (active || done))
                  Text(
                    step.detail!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The stage a failed attempt died in: the furthest stage it reported.
  /// The stream told us how far it got; codeAccepted is the floor.
  CompanionPairingStage _failurePoint() {
    // _stage is `failed` here; the last non-terminal stage rendered is what
    // the rows walked through — recomputed from what we captured.
    if (_hostName != null) return CompanionPairingStage.proving;
    if (_detail != null) return CompanionPairingStage.searching;
    return CompanionPairingStage.codeAccepted;
  }
}

class _Step {
  const _Step(this.stage, this.label, this.detail);

  final CompanionPairingStage stage;
  final String label;
  final String? detail;
}
