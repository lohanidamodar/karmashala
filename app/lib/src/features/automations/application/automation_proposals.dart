import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show WebhookIssued;

import '../../../core/util/clock_provider.dart';
import '../../notifications/application/attention_inbox.dart';
import 'automation_editor_state.dart';
import 'automation_providers.dart';
import 'unattended_preflight.dart';

/// What the owner does with an automation an agent proposed. Turning one on
/// is a person's act, here in the app and nowhere else; it arms the
/// automation as of now and makes it theirs.
class AutomationProposals {
  AutomationProposals(this._ref);

  final Ref _ref;

  /// Every proposal nobody has turned on yet.
  List<Automation> get waiting => [
    for (final automation in _ref.read(automationsDataProvider).getAll())
      if (automation.isProposed) automation,
  ];

  Automation? _of(String id) => _ref.read(automationsDataProvider).getById(id);

  /// Opens [id] in the editor, to read and change before turning it on.
  void review(String id) {
    final proposal = _of(id);
    if (proposal != null) {
      _ref.read(automationEditorProvider.notifier).edit(proposal);
    }
  }

  /// Turns [id] on, armed now. A webhook's secret is made here and answered
  /// to the owner — the agent that proposed it never sees one. Throws
  /// [StateError] with the reason when it could not run unattended.
  Future<WebhookIssued?> turnOn(String id) async {
    final proposal =
        _of(id) ?? (throw StateError('That proposal is no longer here.'));
    if (proposal.startsAgent) {
      final refusal = _ref
          .read(unattendedPreflightProvider)
          .refusalFor(proposal);
      if (refusal != null) throw StateError(refusal.reason);
    }
    final data = _ref.read(automationsDataProvider);
    final stored = await data.saveAndWait(
      proposal.copyWith(
        enabled: true,
        armedAt: _ref.read(clockProvider).nowUtc(),
        clearProposed: true,
      ),
    );
    _ref.read(attentionInboxProvider.notifier).dismiss(proposalInboxId(id));
    return stored.isWebhook ? data.rotateWebhook(stored.id) : null;
  }

  /// Deletes [id]: it never ran, so nothing else goes with it.
  void discard(String id) {
    _ref.read(automationControllerProvider).delete(id);
    _ref.read(attentionInboxProvider.notifier).dismiss(proposalInboxId(id));
  }
}

final automationProposalsProvider = Provider<AutomationProposals>(
  AutomationProposals.new,
);
