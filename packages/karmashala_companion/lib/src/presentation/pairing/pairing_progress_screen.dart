import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';
import '../../application/companion_providers.dart';
import '../companion_chrome.dart';
import '../companion_states.dart';

/// Staged progress for one pairing attempt — code accepted, looking for the
/// desktop, proving keys, paired — with a Retry that re-runs the same attempt.
class PairingProgressScreen extends ConsumerStatefulWidget {
  const PairingProgressScreen({required this.attempt, super.key});

  /// One pairing attempt against the gateway, re-run by Retry.
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
    // Subscribe before the attempt starts so no stage is missed; start it off
    // the build phase so its first events may setState.
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
              constraints: const BoxConstraints(
                maxWidth: companionFocusedWidth,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final step in _steps())
                    _PairingStepRow(
                      label: step.label,
                      detail: step.detail,
                      state: pairingStepStateOf(
                        step: step.stage,
                        current: _stage,
                        failurePoint: _failurePoint(),
                      ),
                    ),
                  if (failed) ...[
                    const SizedBox(height: Insets.lg),
                    Container(
                      padding: const EdgeInsets.all(Insets.lg),
                      decoration: BoxDecoration(
                        // Tint plus words: the sentence carries the meaning and
                        // the colour only supports it.
                        color: SemanticColors.of(context).failureSurface,
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Text(
                        _error ?? 'Pairing failed.',
                        // Prose, not a caption: once it appears it is the only
                        // thing on this screen worth reading.
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                    FilledButton.icon(
                      onPressed: _run,
                      // Unsized: the touch theme already gives every button
                      // glyph Touch.icon.
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
    final capabilities = _capabilities;
    final grants = capabilities == null
        ? null
        : companionGrantsSentence(capabilities);
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

  /// The stage a failed attempt died in — the furthest it reported, with
  /// codeAccepted as the floor.
  CompanionPairingStage _failurePoint() {
    // _stage is `failed` here, so the last non-terminal stage is recomputed
    // from what was captured.
    if (_hostName != null) return CompanionPairingStage.proving;
    if (_detail != null) return CompanionPairingStage.searching;
    return CompanionPairingStage.codeAccepted;
  }
}

/// Where one step of a pairing attempt stands.
enum PairingStepState { done, active, failed, pending }

/// The state of [step] while the attempt is at [current]. On failure the
/// attempt died at [failurePoint], and that row wears the warning.
PairingStepState pairingStepStateOf({
  required CompanionPairingStage step,
  required CompanionPairingStage current,
  required CompanionPairingStage failurePoint,
}) {
  final failed = current == CompanionPairingStage.failed;
  final at = failed ? failurePoint.index : current.index;
  final done = current == CompanionPairingStage.paired
      ? step.index <= at
      : step.index < at;
  if (done) return PairingStepState.done;
  if (step.index != at) return PairingStepState.pending;
  return failed ? PairingStepState.failed : PairingStepState.active;
}

class _Step {
  const _Step(this.stage, this.label, this.detail);

  final CompanionPairingStage stage;
  final String label;
  final String? detail;
}

/// One step of the attempt: its mark, its name, and its detail once reached.
class _PairingStepRow extends StatelessWidget {
  const _PairingStepRow({
    required this.label,
    required this.state,
    this.detail,
  });

  final String label;
  final String? detail;
  final PairingStepState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    // The same size whichever of the four states it is in.
    final mark = UiDensity.of(context).icon + _markGrowth;
    final reached =
        state == PairingStepState.done || state == PairingStepState.active;
    final (Widget icon, Color colour) = switch (state) {
      PairingStepState.done => (
        Icon(AppIcons.checkCircle, size: mark, color: semantic.idle),
        scheme.onSurface,
      ),
      PairingStepState.failed => (
        Icon(AppIcons.warning, size: mark, color: semantic.failure),
        semantic.failure,
      ),
      PairingStepState.active => (
        const InlineSpinner(size: InlineSpinnerSize.medium),
        scheme.onSurface,
      ),
      PairingStepState.pending => (
        Icon(AppIcons.circle, size: mark, color: scheme.outlineVariant),
        scheme.onSurfaceVariant,
      ),
    };
    final detail = this.detail;

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
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colour,
                    fontWeight: reached ? FontWeight.w600 : null,
                  ),
                ),
                if (detail != null && reached)
                  Text(
                    detail,
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

  /// A step's mark, a touch larger than a row glyph so a check reads as done.
  static const _markGrowth = 2.0;
}
