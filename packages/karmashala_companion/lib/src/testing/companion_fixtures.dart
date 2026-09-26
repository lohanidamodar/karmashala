/// Values a companion suite builds its case out of, and the two widths every
/// screen owes CLAUDE.md §6.
library;

import 'dart:ui' show Size;

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

/// The phone size named in CLAUDE.md §11 — the compact width class.
const Size kPhoneSize = Size(390, 844);

/// A tablet in portrait, comfortably past the 600px compact breakpoint: the
/// width class where the companion must stop stretching its lists.
const Size kTabletSize = Size(834, 1112);

/// A session summary with test-friendly defaults.
CompanionSessionSummary summary(
  String id, {
  String? title,
  String project = 'popupbits',
  String? projectId,
  String? projectPath,
  String agentLabel = 'Claude Code  ·  running',
  CompanionSessionStatus status = CompanionSessionStatus.working,
  bool live = false,
  String? branch,
  String? subPath,
  bool worktree = false,
  String? whereabouts,
  CompanionAttention? attention,
  DateTime? lastActivityAt,
  bool archived = false,
  bool folderMissing = false,
  bool imported = false,
  RemoteAttachmentSupport? attachments,
  String? environmentBadge,
  String? environmentName,
  String? environmentId,
  String? environmentKind,
  String? model,
}) => CompanionSessionSummary(
  model: model,
  id: id,
  title: title ?? 'Session $id',
  agentLabel: agentLabel,
  projectName: project,
  projectId: projectId,
  projectPath: projectPath,
  status: status,
  live: live,
  branch: branch,
  subPath: subPath,
  worktree: worktree,
  whereabouts: whereabouts,
  attention: attention,
  lastActivityAt: lastActivityAt,
  archived: archived,
  folderMissing: folderMissing,
  imported: imported,
  attachments: attachments,
  environmentBadge: environmentBadge,
  environmentName: environmentName,
  environmentId: environmentId,
  environmentKind: environmentKind,
);
