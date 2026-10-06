import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../agents/application/agent_providers.dart';
import '../../../remote/application/remote_approval_bindings.dart'
    show chatOpenQuestionProvider;
import '../../application/session_status_providers.dart';
import '../approval_request_card.dart';
import 'plan_approval_card.dart';

/// Sessions whose open ask the chat is drawing under its call right now. The
/// dock steps aside for them, so one set of answers is on screen.
final chatInlineAsksProvider = NotifierProvider<ChatInlineAsks, Set<String>>(
  ChatInlineAsks.new,
);

class ChatInlineAsks extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  // Both are told a microtask late, when the scope may already be gone.
  void shown(String sessionId) {
    if (ref.mounted && !state.contains(sessionId)) {
      state = {...state, sessionId};
    }
  }

  void gone(String sessionId) {
    if (ref.mounted && state.contains(sessionId)) {
      state = {...state}..remove(sessionId);
    }
  }
}

/// Sessions whose open ask was asked to be shown ("Answer the prompt above
/// first" tapped): the card under the call scrolls itself into view, then
/// takes the request.
final chatAskRevealsProvider = NotifierProvider<ChatAskReveals, Set<String>>(
  ChatAskReveals.new,
);

class ChatAskReveals extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void request(String sessionId) {
    if (!state.contains(sessionId)) state = {...state, sessionId};
  }

  void taken(String sessionId) {
    if (ref.mounted && state.contains(sessionId)) {
      state = {...state}..remove(sessionId);
    }
  }
}

/// Whether [report] is asking about the call [toolUseId]: an approval whose
/// hook or protocol request named that call.
bool asksAboutCall(AgentStatusReport? report, String toolUseId) =>
    report != null &&
    report.status == AgentActivityStatus.awaitingApproval &&
    report.waiting == AgentWaitKind.approval &&
    report.toolAsk?.toolUseId == toolUseId;

/// **The pending approval or question, under the call it is about.** The
/// dock's own card and answers, so either place answers the one prompt and
/// both clear when the agent moves on. Nothing at all for any other call.
class ChatToolAsk extends ConsumerStatefulWidget {
  const ChatToolAsk({
    required this.sessionId,
    required this.toolUseId,
    this.toolName,
    super.key,
  });

  final String sessionId;
  final String toolUseId;

  /// The pending call's own tool, which names a plan prompt the screen
  /// shows when no hook said which call it is about.
  final String? toolName;

  @override
  ConsumerState<ChatToolAsk> createState() => _ChatToolAskState();
}

class _ChatToolAskState extends ConsumerState<ChatToolAsk> {
  late final ChatInlineAsks _asks;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _asks = ref.read(chatInlineAsksProvider.notifier);
  }

  @override
  void dispose() {
    if (_shown) _tell(false);
    super.dispose();
  }

  /// Told after the frame: a provider may not change while the tree builds.
  void _tell(bool shown) {
    _shown = shown;
    final sessionId = widget.sessionId;
    scheduleMicrotask(
      () => shown ? _asks.shown(sessionId) : _asks.gone(sessionId),
    );
  }

  /// Scrolls this card wholly into view once laid out, and takes the request.
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    ref.read(chatAskRevealsProvider.notifier).taken(widget.sessionId);
    // The far edge first, then the near one: the answers, then its top.
    for (final policy in const [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ]) {
      Scrollable.ensureVisible(context, alignmentPolicy: policy);
    }
  });

  /// A plan prompt read off the screen: an approval no hook named a call
  /// for, while this pending call is the agent's plan tool.
  bool _screenPlanPrompt(AgentStatusReport? report, AgentRegistry registry) =>
      report != null &&
      report.toolAsk == null &&
      report.status == AgentActivityStatus.awaitingApproval &&
      report.waiting == AgentWaitKind.approval &&
      widget.toolName != null &&
      registry.byId(report.agentId)?.planApproval?.toolName == widget.toolName;

  @override
  Widget build(BuildContext context) {
    final status = agentSessionStatusProvider(widget.sessionId);
    final registry = ref.read(agentRegistryProvider);
    final approval = ref.watch(
      status.select((s) {
        final report = s.asData?.value;
        return asksAboutCall(report, widget.toolUseId) ||
            _screenPlanPrompt(report, registry);
      }),
    );
    // A question names its call in the question itself, read off the hook or
    // the agent's record.
    final questionOpen = ref.watch(
      status.select((s) => s.asData?.value.hasOpenQuestion ?? false),
    );
    final asking =
        approval ||
        questionOpen &&
            ref.watch(
                  chatOpenQuestionProvider(
                    widget.sessionId,
                  ).select((q) => q.value?.toolUseId),
                ) ==
                widget.toolUseId;
    if (asking != _shown) _tell(asking);
    if (!asking) return const SizedBox.shrink();
    if (ref.watch(
      chatAskRevealsProvider.select((s) => s.contains(widget.sessionId)),
    )) {
      _reveal();
    }
    // A plan prompt, when the agent's descriptor says this ask is one.
    final report = ref
        .read(agentSessionStatusProvider(widget.sessionId))
        .asData
        ?.value;
    final descriptor = report == null
        ? null
        : ref.read(agentRegistryProvider).byId(report.agentId);
    final support = descriptor?.planApproval;
    final plan =
        support?.planIn(report?.toolAsk) ??
        (_screenPlanPrompt(report, registry) ? '' : null);
    if (report != null && support != null && plan != null) {
      return Padding(
        key: ValueKey('plan-approval:${widget.toolUseId}'),
        padding: const EdgeInsets.only(top: Insets.sm),
        child: PlanApprovalCard(
          sessionId: widget.sessionId,
          report: report,
          plan: plan,
          support: support,
          agentName: descriptor!.displayName,
        ),
      );
    }
    return Padding(
      key: ValueKey('chat-ask:${widget.toolUseId}'),
      padding: const EdgeInsets.only(top: Insets.sm),
      child: ApprovalRequestCard(
        sessionId: widget.sessionId,
        docked: true,
        inline: true,
        touch: UiDensity.of(context).isTouch,
      ),
    );
  }
}
