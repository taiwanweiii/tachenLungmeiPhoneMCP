/// 推理流程紀錄：一則訊息從送出到回覆，中間每一步發生了什麼
enum TraceKind {
  input,       // 使用者輸入
  mcp,         // MCP 連線 / 工具清單
  llmRequest,  // 送給 AI 模型
  llmResponse, // AI 模型回應
  thinking,    // 模型的思考內容（有提供才會出現）
  toolCall,    // 呼叫 MCP 工具
  toolResult,  // 工具回傳結果
  blocked,     // 被規則攔截
  warning,     // 需要注意的狀況
  error,       // 錯誤
  answer,      // 最終回覆
}

class TraceStep {
  final TraceKind kind;
  final String    title;
  final String?   detail;
  final Duration  elapsed; // 距離開始的時間

  const TraceStep({
    required this.kind,
    required this.title,
    this.detail,
    required this.elapsed,
  });
}

class ReasoningTrace {
  final DateTime _start = DateTime.now();
  final List<TraceStep> steps = [];

  int rounds = 0;                 // 呼叫 AI 模型的次數
  final List<String> toolsCalled = [];

  Duration get total => steps.isEmpty ? Duration.zero : steps.last.elapsed;

  void add(TraceKind kind, String title, {String? detail}) {
    steps.add(TraceStep(
      kind:    kind,
      title:   title,
      detail:  detail,
      elapsed: DateTime.now().difference(_start),
    ));
  }

  bool get hasProblem => steps.any((s) =>
      s.kind == TraceKind.error ||
      s.kind == TraceKind.blocked ||
      s.kind == TraceKind.warning);
}
