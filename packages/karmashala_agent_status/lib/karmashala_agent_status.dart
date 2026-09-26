/// What an agent in a terminal is doing, and answering what it asks: the
/// status the session host keeps per session from hooks and screen, the wire
/// shape it travels in, and the approve/deny, menu and question answers typed
/// into the terminal — one implementation for the host and the app.
library;

export 'src/domain/approval_answer.dart';
export 'src/domain/approval_decision.dart';
export 'src/domain/hosted_agent_status.dart';
export 'src/domain/prompt_answer_request.dart';
export 'src/domain/prompt_evidence.dart';
export 'src/domain/prompt_refusal.dart';
export 'src/domain/status_evidence.dart';
export 'src/service/approval_answerer.dart';
export 'src/service/hosted_status_keeper.dart';
export 'src/service/key_pacer.dart';
export 'src/service/menu_answerer.dart';
export 'src/service/permission_cycle.dart';
export 'src/service/prompt_answering.dart';
export 'src/service/prompt_answers.dart';
export 'src/service/prompt_terminals.dart';
export 'src/service/question_typist.dart';
