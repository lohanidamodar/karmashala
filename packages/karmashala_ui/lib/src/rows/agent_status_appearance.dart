import 'package:flutter/material.dart';

import 'package:agent_cli/descriptors.dart';

import '../app_icons.dart';
import '../design_tokens.dart';

/// Icon, colour and words for one [AgentActivityStatus]. The words are not
/// decoration and colour is never the only carrier; the accent is not used.
({IconData icon, String label, Color Function(SemanticColors) colour})
agentStatusAppearance(AgentActivityStatus status) => switch (status) {
  AgentActivityStatus.working => (
    icon: AppIcons.circleHalf,
    label: 'Working',
    colour: (semantic) => semantic.working,
  ),
  AgentActivityStatus.idle => (
    icon: AppIcons.checkCircle,
    label: 'Idle',
    colour: (semantic) => semantic.idle,
  ),
  AgentActivityStatus.awaitingApproval => (
    icon: AppIcons.warningCircle,
    label: 'Needs you',
    colour: (semantic) => semantic.attention,
  ),
  AgentActivityStatus.failed => (
    icon: AppIcons.xCircle,
    label: 'Failed',
    colour: (semantic) => semantic.failure,
  ),
  AgentActivityStatus.unknown => (
    icon: AppIcons.question,
    label: 'Unknown',
    colour: (semantic) => semantic.neutral,
  ),
};
