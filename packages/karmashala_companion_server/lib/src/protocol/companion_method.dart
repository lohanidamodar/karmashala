/// The companion bindings the session host forwards to a connected app, by
/// the name that travels in a `companionCall`. Each is one of the app's
/// `RemoteHostBindings`, because each needs something only the app has: its
/// status registry, the agents' own records, the composer, the launcher.
///
/// Arguments and results are JSON built from the companion's own payload
/// types, so the host re-serves exactly what the app answered.
enum CompanionMethod {
  listSessions('sessions.list'),
  sessionById('sessions.get'),
  deliveryStage('session.stage'),
  transcript('session.transcript'),
  recordState('session.record_state'),
  sendPrompt('prompt.send'),
  answerApproval('approval.answer'),
  approvalEvidence('approval.evidence'),
  answerQuestion('question.answer'),
  answerMenu('menu.answer'),
  usage('usage.get'),
  listWorkspace('workspace.list'),
  listProjects('projects.list'),
  startSession('session.start'),
  addProject('project.add'),
  resumeSession('session.resume'),
  beginAttachment('attachment.begin'),
  writeAttachmentChunk('attachment.chunk'),
  discardAttachment('attachment.discard'),
  sessionOptions('session.options'),
  configureSession('session.configure');

  const CompanionMethod(this.wire);

  final String wire;

  static CompanionMethod? tryParse(String wire) => _byWire[wire];

  static final Map<String, CompanionMethod> _byWire = {
    for (final method in values) method.wire: method,
  };
}
