import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/ollama_models.dart';
import '../models/mcp_models.dart';
import '../models/skill_model.dart';
import '../models/reasoning_trace.dart';
import '../core/utils/link_launcher.dart';
import '../features/cabinet/wall.dart';
import 'mcp_client_service.dart';
import 'ollama_service.dart';

/// 某一刻的對話狀態（給對話分支用）
class ChatSnapshot {
  final List<OllamaMessage> messages; // 不含 system
  final Map<String, dynamic>? pendingOrderArgs;
  const ChatSnapshot(this.messages, this.pendingOrderArgs);
}

class ChatOrchestrator {
  final OllamaService    _ollama;
  final McpClientService _mcp;

  final List<OllamaMessage> _history  = [];
  final List<OllamaTool>    _allTools = [];

  bool        _initialized      = false;
  bool        _lastMcpConnected = false;
  String      _lastMcpSignature = '';   // 已啟用 MCP Server 的組合
  SkillModel? _currentSkill;

  Function(String)? onLog;
  Function(String toolName, String args, String result)? onToolCall;

  ChatOrchestrator(this._ollama, this._mcp);

  // ── 初始化 ────────────────────────────────────────────
  Future<void> initializeAsync({
    String promptName = 'customer_service',
    Map<String, String>? promptArgs,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _lastMcpSignature = _mcp.enabledSignature;
    if (!_mcp.hasEnabledServers) {
      _lastMcpConnected = false;
      onLog?.call('ℹ️ 未啟用任何 MCP Server，使用純對話模式');
      return;
    }
    onLog?.call('🌐 MCP = ${_mcp.serverUrl}');
    onLog?.call('MCP Server 連線中...');
    await _mcp.initializeAsync();
    _lastMcpConnected = true;
    onLog?.call('✅ MCP Server 連線成功');

    // 不再載入 MCP 的 customer_service prompt：
    // 它是舊版內容（「美麗窗簾」、已停用的工具、要求用表情符號），
    // 而且以 user 訊息塞進對話紀錄，會一直干擾模型。角色設定改由 Skill 的系統提示負責。

    final tools = await _mcp.listToolsAsync();
    for (final t in tools) {
      // ✅ 加 log 確認 schema 格式
      onLog?.call('📋 Tool: ${t.name} | Schema: ${jsonEncode(t.inputSchema)}');
      _allTools.add(OllamaTool(
        function: OllamaToolDef(
          name:        t.name,
          description: t.description,
          parameters:  _patchSchema(t.inputSchema),  // ✅ 修補 schema
        ),
      ));
    }
    onLog?.call('✅ 載入 ${tools.length} 個工具');
  }

  // ── ✅ 新增：Schema 修補，確保 Ollama 能正確識別工具 ──
  Map<String, dynamic>? _patchSchema(Map<String, dynamic>? schema) {
    if (schema == null) return {'type': 'object', 'properties': {}};

    final patched = Map<String, dynamic>.from(schema);
    patched.putIfAbsent('type', () => 'object');
    patched.putIfAbsent('properties', () => <String, dynamic>{});

    // 補上 required（qwen2.5 沒有 required 時有時不觸發）
    final props = patched['properties'] as Map<String, dynamic>?;
    if (props != null && props.isNotEmpty && !patched.containsKey('required')) {
      patched['required'] = props.keys.toList();
    }

    // 移除 Ollama 不認識的 JSON Schema 欄位
    patched.remove('\$schema');
    patched.remove('\$id');
    patched.remove('additionalProperties');

    return patched;
  }

  // ── 套用 Skill ────────────────────────────────────────
  void applySkill(SkillModel skill, {bool force = false}) {
    if (!force && _currentSkill?.id == skill.id) return;
    _currentSkill = skill;
    _history.removeWhere((m) => m.role == 'system');
    if (skill.systemPrompt.isNotEmpty) {
      _history.insert(
        0,
        OllamaMessage(role: 'system', content: _buildSystemPrompt(skill)),
      );
    }
    onLog?.call('🎯 已切換 Skill：${skill.name}');
  }

  // ── Layer 1：組裝完整 System Prompt ──────────────────
  static String _nowDescription() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final offset = now.timeZoneOffset;
    final sign   = offset.isNegative ? '-' : '+';
    final tz     = 'UTC$sign${two(offset.inHours.abs())}:${two(offset.inMinutes.abs() % 60)}';
    return '今天是 ${now.year}-${two(now.month)}-${two(now.day)}'
        '（星期${weekdays[now.weekday - 1]}），'
        '現在時間 ${two(now.hour)}:${two(now.minute)}（$tz）。';
  }

  String _buildSystemPrompt(SkillModel skill) {
    final buffer = StringBuffer();

    buffer.writeln(skill.systemPrompt);
    buffer.writeln();

    // 模型不知道今天幾號，一定要告訴它，否則「今天、本週、上個月」會用訓練資料的年份亂猜
    buffer.writeln('【目前時間】');
    buffer.writeln(_nowDescription());
    buffer.writeln('使用者提到「今天、昨天、本週、這個月、上個月」等相對時間時，'
        '一律以上面的日期換算成實際日期，再填入工具參數（格式 YYYY-MM-DD）。');
    buffer.writeln();

    if (skill.isNoToolsMode) {
      buffer.writeln('【工具狀態】');
      buffer.writeln('目前為純對話模式，你沒有任何工具可以使用。');
      buffer.writeln();
    } else {
      final activeToolNames = _activeTools.map((t) => t.function.name).toList();
      if (activeToolNames.isEmpty) {
        buffer.writeln('【工具狀態】');
        buffer.writeln('目前沒有任何可用工具（MCP Server 可能尚未連線）。');
        buffer.writeln();
      } else {
        buffer.writeln('【核心指令 - 最高優先級】');
        buffer.writeln('當使用者詢問任何資料查詢相關問題時，你必須立即呼叫對應的工具函數。');
        buffer.writeln('不要用文字回答，不要說「我可以幫你查」，直接呼叫工具。');
        buffer.writeln('只要問題涉及以下工具的功能範圍，就必須呼叫工具，不得例外。');
        buffer.writeln();
        buffer.writeln('【可用工具清單 - 遇到相關問題必須呼叫】');
        for (final name in activeToolNames) {
          buffer.writeln('- $name');
        }
        buffer.writeln();
      }
    }

    buffer.writeln('【行為規範】');
    buffer.writeln('1. 有工具可用時，必須先呼叫工具取得資料，再根據資料回答。');
    buffer.writeln('2. 若沒有對應的工具，才可以用文字告知使用者。');
    buffer.writeln('3. 工具呼叫失敗時，如實告知，不要猜測數值。');
    buffer.writeln('4. 不要在呼叫工具前就給出答案。');
    buffer.writeln('5. 回覆使用者時，不要出現工具或函式的英文名稱（例如 draft_job_order、'
        'query_job_list），一律用中文描述要做的事（例如「建立訂單草稿」「查詢訂單清單」）。'
        '使用者不需要知道系統內部的程式名稱。');
    buffer.writeln('6. 回答精簡：直接給答案，不要開場白、客套結尾，不要重複使用者的問題，'
        '已經回答過的資料不要再問。');

    if (_voiceReply) {
      buffer.writeln();
      buffer.writeln('【語音回答】');
      buffer.writeln('使用者是用語音問的，你的回答會被唸出來：用 1～3 句口語回答，'
          '不要用表格、條列、Markdown 符號；多筆資料只講總數和最重要的一兩筆。');
    }

    return buffer.toString();
  }

  // ── 依 Skill 過濾工具 ─────────────────────────────────
  List<OllamaTool> get _activeTools {
    final skill = _currentSkill;
    if (skill == null || skill.isAllToolsAllowed) return _allTools;
    if (skill.isNoToolsMode) return [];
    return _allTools
        .where((t) => skill.isToolAllowed(t.function.name))
        .toList();
  }

  // ── Layer 4：歷史長度修剪 ─────────────────────────────
  void _trimHistory({int maxTurns = 10}) {
    final systemMsgs  = _history.where((m) => m.role == 'system').toList();
    final otherMsgs   = _history.where((m) => m.role != 'system').toList();
    final maxMessages = maxTurns * 3;
    if (otherMsgs.length <= maxMessages) return;

    final trimmed = otherMsgs.skip(otherMsgs.length - maxMessages).toList();
    _history
      ..clear()
      ..addAll(systemMsgs)
      ..addAll(trimmed);
    onLog?.call('✂️ 歷史修剪：保留最近 $maxTurns 輪對話');
  }

  // ── Layer 5：MCP 連線狀態即時更新 ────────────────────
  Future<void> _refreshToolContext() async {
    // 沒啟用任何 MCP Server → 不 ping，直接視為離線
    final signature     = _mcp.enabledSignature;
    final configChanged = signature != _lastMcpSignature;
    final isConnected   =
        _mcp.hasEnabledServers ? await _mcp.pingAsync() : false;
    if (!configChanged && isConnected == _lastMcpConnected) return;
    _lastMcpSignature = signature;
    _lastMcpConnected = isConnected;

    if (isConnected) {
      try {
        if (configChanged) await _mcp.initializeAsync();
        _allTools.clear();
        final tools = await _mcp.listToolsAsync();
        for (final t in tools) {
          _allTools.add(OllamaTool(
            function: OllamaToolDef(
              name:        t.name,
              description: t.description,
              parameters:  _patchSchema(t.inputSchema),  // ✅
            ),
          ));
        }
        onLog?.call('🟢 MCP 重新連線，已更新 ${tools.length} 個工具');
        _t(TraceKind.mcp, 'MCP 狀態改變，重新載入 ${tools.length} 個工具');
      } catch (e) {
        _t(TraceKind.error, 'MCP 重新載入工具失敗', detail: '$e');
      }
    } else {
      _allTools.clear();
      onLog?.call(_mcp.hasEnabledServers
          ? '🔴 MCP 離線，更新 System Prompt 提示'
          : 'ℹ️ 未啟用 MCP Server，工具已移除');
    }

    if (_currentSkill == null) return;
    _history.removeWhere((m) => m.role == 'system');
    _history.insert(0, OllamaMessage(
      role:    'system',
      content: _buildSystemPrompt(_currentSkill!),
    ));
  }

  // ── 強制重新連線 ──────────────────────────────────────
  Future<({bool ollamaOk, bool mcpOk, int toolCount})> reconnect() async {
    onLog?.call('🔄 強制重新連線中...');
    _lastMcpConnected = false;
    _initialized      = false;

    bool mcpOk     = false;
    int  toolCount = 0;
    _lastMcpSignature = _mcp.enabledSignature;
    _allTools.clear();
    try {
      _mcp.reset();
      if (!_mcp.hasEnabledServers) {
        throw Exception('未啟用任何 MCP Server');
      }
      await _mcp.initializeAsync();
      mcpOk = true;

      _allTools.clear();
      final tools = await _mcp.listToolsAsync();
      for (final t in tools) {
        _allTools.add(OllamaTool(
          function: OllamaToolDef(
            name:        t.name,
            description: t.description,
            parameters:  _patchSchema(t.inputSchema),  // ✅
          ),
        ));
      }
      toolCount         = tools.length;
      _lastMcpConnected = true;
      _initialized      = true;
      onLog?.call('✅ 重新連線成功，載入 $toolCount 個工具');
    } catch (e) {
      onLog?.call('❌ MCP 重新連線失敗：$e');
    }

    if (_currentSkill != null) {
      _history.removeWhere((m) => m.role == 'system');
      _history.insert(0, OllamaMessage(
        role:    'system',
        content: _buildSystemPrompt(_currentSkill!),
      ));
    }

    return (ollamaOk: true, mcpOk: mcpOk, toolCount: toolCount);
  }

  // ── Layer 2：回應內容驗證 ─────────────────────────────
  String _validateResponse(String content, List<String> toolsUsed) {
    if (toolsUsed.isNotEmpty) return content;

    final suspiciousPatterns = [
      RegExp(r'\d+(\.\d+)?°C'),
      RegExp(r'\d+(\.\d+)?度'),
      RegExp(r'濕度.*?\d+(\.\d+)?%'),
      RegExp(r'電量.*?\d+(\.\d+)?%'),
      RegExp(r'目前.{0,10}(是|為|：)\s*\d+'),
      RegExp(r'現在.{0,10}(是|為|：)\s*\d+'),
    ];

    for (final pattern in suspiciousPatterns) {
      if (pattern.hasMatch(content)) {
        onLog?.call('⚠️ 攔截可疑回應（無工具卻含感測數值）');
        _t(TraceKind.blocked, '攔截回答：沒用工具卻出現具體數值',
            detail: '符合規則 ${pattern.pattern}，判定可能是模型編造，'
                '已換成預設說明\n\n原本的回答：\n${_clip(content)}');
        return '抱歉，我目前沒有工具可以查詢這項即時資料，無法提供準確數值。\n\n'
            '請確認 MCP Server 是否已連線，或此 Skill 是否已開啟對應工具。';
      }
    }
    return content;
  }

  // ── 推理流程紀錄 ──────────────────────────────────────
  ReasoningTrace? _trace;

  /// 最近一次 sendMessageAsync 的推理流程
  ReasoningTrace? get lastTrace => _trace;

  /// 最近一次回覆中，工具標記「給使用者」的內容裡的連結（例如詢單頁），聊天頁會自動開啟並顯示按鈕
  List<({String label, String url})> _lastActionLinks = const [];
  List<({String label, String url})> get lastActionLinks => _lastActionLinks;

  /// 這次回覆中模型呼叫了「挑選櫃子」工具：聊天頁要彈出產品挑選畫面，
  /// 使用者選好後把結果當成使用者說的話送回來
  bool _lastPickRequested = false;
  bool get lastPickRequested => _lastPickRequested;

  /// 對話裡最近一次下單（quick_order）帶的客戶名稱。開系統櫃配置畫面時用來預填
  /// 「建立詢單」的客戶欄位。不會每輪重設，整段對話都記得。
  String? _lastCustomer;

  /// 對話裡最近一次下單（quick_order）帶的牆面（wallName，已整理成 back/left/right/front）。
  /// AI 在下單參數裡已經依使用者說的方位填了牆面，但之後只叫「打開畫面」不帶 wall 時，
  /// 用它當已選櫃子的牆面，櫃子才會擺在使用者說的那一邊。
  String? _lastOrderWall;
  String? get lastOrderWall => _lastOrderWall;
  String? get lastCustomer => _lastCustomer;

  /// 這次回覆中模型呼叫了 open_config_view：使用者想看畫面／介面。
  /// 是否呼叫由 AI 判斷（工具寫在 MCP），聊天頁只負責打開系統櫃配置網頁並收起鍵盤。
  bool _lastOpenConfigRequested = false;
  bool get lastOpenConfigRequested => _lastOpenConfigRequested;

  /// open_config_view 帶了 wall：把已選櫃子換到那面牆（可只換某個品號）。沒帶就是 null。
  /// 回傳 {wall: 代號, productNo: 品號或 null}
  /// 一輪裡可能有好幾個（每個櫃子各一面牆／各一個順序），依呼叫順序全部記下來。
  final List<Map<String, String?>> _lastMoves = [];
  List<Map<String, String?>> get lastMoves => List.unmodifiable(_lastMoves);

  /// 模型呼叫挑選工具時帶的「預先選好」內容（產品、數量、使用者已說的規格，或分不出來的候選）。
  /// 沒帶就是 null（畫面完整顯示目錄讓使用者自己選）。
  Map<String, dynamic>? _lastPickPreselect;
  Map<String, dynamic>? get lastPickPreselect => _lastPickPreselect;

  /// 這一輪最近一次 search_products 找到的品號。小模型常搜完卻忘了把結果帶進 pick_product，
  /// 結果挑選畫面顯示完整目錄；pick_product 沒帶任何參數時，用這份清單補上 candidates。
  List<String>? _lastSearchNos;

  /// 從 search_products 的回傳文字取出品號（每行「- **A01** 名稱」）。
  /// 超過 20 個會被截斷（有「…還有 N 個」）：只列出一部分，過濾會把其他產品藏起來，回傳 null 不過濾。
  @visibleForTesting
  static List<String>? parseSearchProductNos(String text) {
    if (text.contains('…還有')) return null;
    final nos = <String>[
      for (final m in RegExp(r'^\s*-\s*\*\*([^*\s]+)\*\*', multiLine: true)
          .allMatches(text))
        m.group(1)!,
    ];
    return nos.isEmpty ? null : nos;
  }

  @visibleForTesting
  static Map<String, dynamic>? buildPreselect(Map<String, dynamic> a) {
    final productNo = '${a['productNo'] ?? ''}'.trim();
    final specs = a['specs'] is Map
        ? Map<String, dynamic>.from(a['specs'] as Map)
        : <String, dynamic>{};
    // 小模型常把規格直接放在最外層（width / direction…），一併接受
    for (final k in ['width', 'height', 'depth', 'direction', 'marginB']) {
      if (a[k] != null && !specs.containsKey(k)) specs[k] = a[k];
    }
    if (productNo.isNotEmpty) {
      final q = (a['quantity'] is num) ? (a['quantity'] as num).toInt() : 1;
      // 使用者說了方位（左邊／右邊／後面）時 AI 會帶 wall；沒說就不帶，預設後牆
      final wall = normalizeWall(a['wall']);
      return {
        'items': [
          {
            'productNo': productNo,
            'quantity': q < 1 ? 1 : q,
            'specs': specs,
            if (wall != null) 'wall': wall,
          },
        ],
        // 一律停在規格頁，讓使用者看過、按「加入」（或說「加入」）才送出
        'autoAdd': false,
      };
    }
    final cands = a['candidates'];
    if (cands is List && cands.isNotEmpty) {
      return {'candidates': [for (final c in cands) '$c']};
    }
    return null;
  }

  void _t(TraceKind kind, String title, {String? detail}) =>
      _trace?.add(kind, title, detail: detail);

  static String _clip(String s, [int max = 1500]) =>
      s.length <= max ? s : '${s.substring(0, max)}…（共 ${s.length} 字，已截斷）';

  /// 這次是語音提問：回答要短、適合唸出來
  bool _voiceReply = false;

  /// 下一次詢問模型時要多加的一句提醒（不寫進對話紀錄）
  String? _nudge;

  /// 目前的進度（例如「查詢龍美系統櫃訂單中…」），聊天頁顯示在等待動畫旁
  final ValueNotifier<String?> progress = ValueNotifier<String?>(null);

  /// 等使用者按「確認建立」的新訂單參數（quick_order 摘要成功時記下）
  Map<String, dynamic>? _pendingOrderArgs;
  bool get hasPendingOrder => _pendingOrderArgs != null;

  /// 這次回覆是否產生了待確認的新訂單摘要（聊天頁據此顯示按鈕）
  bool _lastReplyPendingOrder = false;
  bool get lastReplyPendingOrder => _lastReplyPendingOrder;

  // ── 傳送訊息 ──────────────────────────────────────────
  /// [aiNote]：只給模型看的補充（例如配置畫面的牆面與座標）。會接在使用者訊息後面送給模型，
  /// 但不會顯示在聊天畫面（畫面上顯示的是 [userMessage]）。
  Future<({String content, List<String> toolsUsed})> sendMessageAsync(
      String userMessage, {bool voice = false, String? aiNote}) async {
    _voiceReply = voice;
    _lastReplyPendingOrder = false;
    _lastPickRequested = false;
    _lastOpenConfigRequested = false;
    _lastMoves.clear();
    _lastPickPreselect = null;
    _lastSearchNos = null;
    final trace = _trace = ReasoningTrace();
    _lastActionLinks = const [];
    trace.add(TraceKind.input, '收到訊息',
        detail: (aiNote == null || aiNote.isEmpty)
            ? userMessage
            : '$userMessage\n\n（另附只給模型看的備註）\n$aiNote');
    try {
      return await _sendMessageTraced(userMessage, trace, aiNote: aiNote);
    } catch (e) {
      trace.add(TraceKind.error, '處理失敗', detail: '$e');
      rethrow;
    } finally {
      progress.value = null;
    }
  }

  Future<({String content, List<String> toolsUsed})> _sendMessageTraced(
      String userMessage, ReasoningTrace trace, {String? aiNote}) async {
    _trimHistory();
    await _refreshToolContext();

    // MCP 與工具狀態
    if (!_mcp.hasEnabledServers) {
      _t(TraceKind.mcp, '未啟用任何 MCP Server → 純對話，沒有工具可用');
    } else {
      _t(_lastMcpConnected ? TraceKind.mcp : TraceKind.warning,
          _lastMcpConnected
              ? 'MCP 已連線，共 ${_allTools.length} 個工具'
              : 'MCP 連不上，本次沒有工具可用',
          detail: _mcp.serverUrl);
    }

    _history.add(OllamaMessage(
        role: 'user',
        content: (aiNote == null || aiNote.isEmpty)
            ? userMessage
            : '$userMessage\n\n$aiNote'));

    final tools         = _activeTools;
    final usedToolNames = <String>[];
    // MCP 標記 audience=user 的內容（例如訂單摘要、送出連結）：直接顯示給使用者，
    // 不靠模型轉述。同一個工具呼叫多次只留最後一次。
    final userBlocks    = <String, String>{};

    // 每次送出前都依「目前實際的工具」重建系統提示，
    // 避免 Skill 套用時工具還沒載入，提示卻一直寫「沒有工具」
    if (_currentSkill != null) {
      _history.removeWhere((m) => m.role == 'system');
      _history.insert(0, OllamaMessage(
        role:    'system',
        content: _buildSystemPrompt(_currentSkill!),
      ));
    }

    final skillName = _currentSkill?.name ?? '（無）';
    if (_allTools.isNotEmpty) {
      _t(tools.isEmpty ? TraceKind.warning : TraceKind.mcp,
          'Skill「$skillName」允許 ${tools.length}/${_allTools.length} 個工具',
          detail: tools.isEmpty
              ? '這個 Skill 沒有開放任何工具'
              : tools.map((t) => '• ${t.function.name}'
                  '${t.function.description == null ? '' : '：${t.function.description}'}')
                  .join('\n'));
    }

    final systemPrompt = _history
        .where((m) => m.role == 'system')
        .map((m) => m.content ?? '')
        .join('\n\n');

    // ✅ 修正：分開追蹤「最後的文字回應」
    String? finalContent;
    var exhausted = true; // 5 輪都在呼叫工具、沒有給出最終回答

    var retriedEmpty  = false; // 模型回空白時只重試一次
    var retriedIntent = false; // 模型只說「要做什麼」沒呼叫工具時只重試一次
    String? lastToolResult;    // 模型一直回空白時，至少把工具結果給使用者看

    for (int i = 0; i < 5; i++) {
      trace.rounds = i + 1;
      _t(TraceKind.llmRequest,
          '第 ${i + 1} 輪：詢問 ${_ollama.modelLabel}',
          detail: '送出 ${_history.length} 則訊息、${tools.length} 個工具'
              '${i == 0 && systemPrompt.isNotEmpty ? '\n\n【系統提示】\n${_clip(systemPrompt)}' : ''}');

      progress.value = usedToolNames.isEmpty && i == 0 ? '思考中…' : '整理回答中…';
      final response = await _ollama.chatAsync(
        // 重試時多一句提醒（不寫進對話紀錄）
        messages: _nudge != null
            ? [..._history, OllamaMessage(role: 'user', content: _nudge)]
            : _history,
        tools:    tools.isNotEmpty ? tools : null,
      );
      _nudge = null;
      if (response == null) {
        _t(TraceKind.error, '模型沒有回傳任何訊息');
        exhausted = false;
        break;
      }

      onLog?.call('🤖 Ollama 回應 [輪$i]: toolCalls=${response.toolCalls?.length ?? 0}, content="${response.content ?? ""}"');

      if (response.thinking != null) {
        _t(TraceKind.thinking, '模型的思考內容', detail: _clip(response.thinking!));
      }

      final calls = response.toolCalls ?? const <OllamaToolCall>[];
      if (calls.isNotEmpty) {
        _t(TraceKind.llmResponse,
            '模型決定呼叫 ${calls.length} 個工具',
            detail: [
              if ((response.content ?? '').trim().isNotEmpty)
                '附帶文字：${response.content}',
              ...calls.map((c) =>
                  '• ${c.function.name}(${jsonEncode(c.function.arguments)})'),
            ].join('\n'));
      } else {
        final text = response.content ?? '';
        _t(text.trim().isEmpty ? TraceKind.warning : TraceKind.llmResponse,
            text.trim().isEmpty ? '模型回覆了空白內容' : '模型給出最終回答',
            detail: text.trim().isEmpty
                ? '沒有文字也沒有工具呼叫'
                    '${response.thinking != null ? '（只有思考內容）' : ''}'
                : _clip(text));
      }

      if (response.toolCalls != null && response.toolCalls!.isNotEmpty) {
        // ✅ 修正：加入 assistant 訊息（含 tool_calls）
        _history.add(response);

        for (final tc in response.toolCalls!) {
          final fn = tc.function;

          // Skill 不允許此工具
          if (_currentSkill != null && !_currentSkill!.isToolAllowed(fn.name)) {
            _t(TraceKind.blocked, '攔截「${fn.name}」：Skill 不允許',
                detail: '目前 Skill「$skillName」沒有開放這個工具，'
                    '已告訴模型此功能不可用');
            onLog?.call('⛔ Skill 不允許工具：${fn.name}，已略過');
            _history.add(OllamaMessage(
              role:       'tool',
              name:       fn.name,
              toolCallId: tc.id,
              content: '工具「${fn.name}」在目前的 Skill 模式下不被允許，請告知使用者此功能目前不可用。',
            ));
            continue;
          }

          // 密碼不可以經過 AI（會留在聊天紀錄、也會送到模型）：帶密碼的工具呼叫一律攔下
          if (fn.arguments.keys.any((k) => k.toLowerCase().contains('password'))) {
            _t(TraceKind.blocked, '攔截「${fn.name}」：參數含密碼',
                detail: '密碼不經過 AI，已請使用者改用設定頁或系統登入畫面');
            _history.add(OllamaMessage(
              role:       'tool',
              name:       fn.name,
              toolCallId: tc.id,
              content: '基於安全，密碼不能透過聊天輸入。請告訴使用者不要在聊天裡提供密碼，'
                  '改由系統的登入或設定畫面處理。',
            ));
            continue;
          }

          onLog?.call('🔧 呼叫工具：${fn.name}（參數：${jsonEncode(fn.arguments)}）');
          _t(TraceKind.toolCall, '呼叫 MCP 工具「${fn.name}」',
              detail: '參數：${const JsonEncoder.withIndent('  ').convert(fn.arguments)}');
          trace.toolsCalled.add(fn.name);
          String toolResult;
          progress.value = '${toolDisplayName(fn.name)}中…';
          // 新訂單：正式建立只能由使用者按「確認建立」按鈕；模型自己帶 confirmed=true 一律改成只取摘要
          var callArgs = fn.arguments;
          final isOrder = fn.name == 'quick_order';
          if (isOrder) {
            final cust = '${callArgs['customer'] ?? ''}'.trim();
            if (cust.isNotEmpty) _lastCustomer = cust;
            _lastOrderWall = normalizeWall(callArgs['wallName']);
          }
          if (isOrder && callArgs['confirmed'] == true) {
            callArgs = Map<String, dynamic>.from(callArgs)..remove('confirmed');
            _t(TraceKind.blocked, '正式建立訂單只能按「確認建立」按鈕',
                detail: '模型想直接建立，已改成只產生摘要');
          }
          try {
            final result  = await _mcp.callToolAsync(fn.name, callArgs);
            if (fn.name == 'search_products' && result?.isError != true) {
              _lastSearchNos = parseSearchProductNos((result?.content ?? <ToolContent>[])
                  .where((c) => c.type == 'text')
                  .map((c) => c.text ?? '')
                  .join('\n'));
            }
            if (fn.name == 'open_config_view' && result?.isError != true) {
              _lastOpenConfigRequested = true;
              final mw = normalizeWall(callArgs['wall']);
              final no = '${callArgs['productNo'] ?? ''}'.trim();
              final pos = int.tryParse('${callArgs['position'] ?? ''}');
              final hasPos = pos != null && pos >= 1 && no.isNotEmpty;
              if (mw != null || hasPos) {
                _lastMoves.add({
                  'wall': mw,
                  'productNo': no.isEmpty ? null : no,
                  if (hasPos) 'position': '$pos',
                  if (no.isNotEmpty && (int.tryParse('${callArgs['count'] ?? ''}') ?? 0) >= 1)
                    'count': '${int.parse('${callArgs['count']}')}',
                });
              }
              _t(TraceKind.answer, '要在使用者畫面打開系統櫃配置',
                  detail: '聊天頁會打開系統櫃配置網頁、帶入已選的櫃子，並收起鍵盤');
            }
            if (fn.name == 'pick_product' && result?.isError != true) {
              _lastPickRequested = true;
              _lastPickPreselect = buildPreselect(callArgs);
              final searched = _lastSearchNos;
              if (_lastPickPreselect == null && searched != null) {
                // 模型沒帶 candidates：用剛搜尋到的結果補上，不要顯示完整目錄
                _lastPickPreselect = {'candidates': searched};
                _t(TraceKind.warning, '模型沒帶 candidates，已用剛搜尋到的品號補上',
                    detail: searched.join('、'));
              }
              _t(TraceKind.answer, '要請使用者從目錄挑選櫃子',
                  detail: _lastPickPreselect == null
                      ? '聊天頁會彈出產品挑選畫面，選好後把結果送回來'
                      : '聊天頁會彈出挑選畫面並預先選好：\n'
                          '${const JsonEncoder.withIndent('  ').convert(_lastPickPreselect)}');
            }
            final forUser = result?.content
                ?.where((c) => c.type == 'text' && c.isForUser)
                .map((c) => (c.text ?? '').trim())
                .where((t) => t.isNotEmpty)
                .join('\n\n') ?? '';
            if (forUser.isNotEmpty) {
              userBlocks[fn.name] = forUser;
              _t(TraceKind.toolResult, '「${fn.name}」有內容直接顯示給使用者',
                  detail: _clip(forUser));
            }
            final rawText = result?.content
                ?.where((c) => c.type == 'text')
                .map((c) => c.text ?? '')
                .join('\n')
                .trim() ?? '';

            if (rawText.isEmpty) {
              toolResult = '工具「${fn.name}」回傳空結果，請告知使用者目前無法取得此資訊。';
              _t(TraceKind.warning, '「${fn.name}」回傳空結果');
            } else {
              toolResult = rawText;
              usedToolNames.add(fn.name);
              onLog?.call('✅ 工具結果：$toolResult');
              _t(TraceKind.toolResult, '「${fn.name}」回傳結果',
                  detail: _clip(rawText));
            }
            if (isOrder) {
              final ok = result?.isError != true && forUser.contains('新訂單摘要');
              _pendingOrderArgs      = ok ? Map<String, dynamic>.from(callArgs) : null;
              _lastReplyPendingOrder = ok;
              if (ok) {
                toolResult = '摘要已經顯示在使用者畫面上，下面有「確認建立」和「修改」按鈕。'
                    '請只回一句「請確認以上內容，沒問題請按「確認建立」。」，'
                    '不要重貼摘要，也不要自己建立訂單。';
              }
            }
          } catch (e) {
            toolResult = '工具「${fn.name}」呼叫失敗（錯誤：$e），請告知使用者目前無法取得此資訊。';
            onLog?.call('❌ 工具呼叫失敗：${fn.name} → $e');
            _t(TraceKind.error, '「${fn.name}」呼叫失敗', detail: '$e');
          }

          lastToolResult = toolResult;
          onToolCall?.call(fn.name, jsonEncode(fn.arguments), toolResult);
          _history.add(OllamaMessage(
              role: 'tool', name: fn.name, toolCallId: tc.id, content: toolResult));
        }
        // ✅ 繼續下一輪，讓 Ollama 根據工具結果生成最終回答
      } else if ((response.content ?? '').trim().isEmpty && !retriedEmpty) {
        // 小模型拿到工具結果後偶爾回空白：提醒一次再問
        retriedEmpty = true;
        _nudge = '請根據上面的工具結果，用繁體中文簡短回答我剛才的問題。';
        _t(TraceKind.warning, '模型回覆空白 → 重試一次');
        continue;
      } else if (!retriedIntent && tools.isNotEmpty && trace.toolsCalled.isEmpty &&
          _looksLikeIntentOnly(response.content ?? '')) {
        // 小模型偶爾只回「查詢訂單清單」這種動作名稱卻沒呼叫工具：提醒一次再問
        retriedIntent = true;
        _nudge = '請直接呼叫對應的工具完成我剛才的要求，不要只描述要做什麼。';
        _t(TraceKind.warning, '模型只說要做什麼、沒有呼叫工具 → 提醒後重試');
        continue;
      } else {
        // ✅ 沒有 tool_calls → 這是最終文字回答
        finalContent = response.content;
        exhausted = false;
        // ✅ 修正：不在這裡加入 history，loop 結束後統一加
        break;
      }
    }

    if (exhausted) {
      _t(TraceKind.warning, '已達 5 輪上限，模型仍在呼叫工具',
          detail: '模型一直沒有給出最終文字回答，只好停止');
    }

    final hasModelText = finalContent?.trim().isNotEmpty == true;
    // 模型沒給文字但工具有結果：直接顯示工具結果，比「無法處理」有用
    final fallbackTool = !hasModelText && userBlocks.isEmpty &&
        (lastToolResult?.trim().isNotEmpty ?? false) &&
        usedToolNames.isNotEmpty;
    if (fallbackTool) {
      _t(TraceKind.warning, '模型沒有回答 → 直接顯示工具結果');
    }
    final rawContent = hasModelText
        ? finalContent!
        : fallbackTool
            ? lastToolResult!
            : (userBlocks.isNotEmpty ? '' : '抱歉，我無法處理您的請求。');
    if (!hasModelText && userBlocks.isEmpty && !fallbackTool) {
      _t(TraceKind.warning, '沒有可用的回答 → 改用預設回覆',
          detail: '回覆「抱歉，我無法處理您的請求。」');
    }
    var modelContent = _validateResponse(rawContent, usedToolNames);
    // 有待確認的新訂單：不用模型自己的文字，固定提醒按按鈕
    // （小模型會編造「已建立、案件編號 xxx」，使用者會誤以為已經建好）
    if (_lastReplyPendingOrder) {
      if (modelContent.trim().isNotEmpty) {
        _t(TraceKind.blocked, '不採用模型的文字，改成固定提醒',
            detail: '有待確認的新訂單時，訂單只能按按鈕建立\n\n'
                '模型原本的回答：\n${_clip(modelContent)}');
      }
      modelContent = '訂單**還沒建立**。請確認以上內容，沒問題請按「確認建立」；要改的話按「修改」。';
    }

    // 工具要直接給使用者看的內容放在前面；模型已經貼過的就不重複
    final shownBlocks = userBlocks.values
        .where((b) => !_alreadyContains(modelContent, b))
        .toList();
    _lastActionLinks = userBlocks.values.expand(extractMarkdownLinks).toList();
    if (_lastActionLinks.isNotEmpty) {
      _t(TraceKind.answer, '偵測到 ${_lastActionLinks.length} 個要開啟的連結',
          detail: _lastActionLinks.map((l) => '• ${l.label}\n  ${l.url}').join('\n'));
    }
    final content = [...shownBlocks, if (modelContent.trim().isNotEmpty) modelContent]
        .join('\n\n');
    _t(TraceKind.answer, '最終回覆',
        detail: '${_clip(content)}'
            '${usedToolNames.isEmpty ? '' : '\n\n資料來源：${usedToolNames.join('、')}'}');

    // ✅ 修正：只在最後加一次 assistant 訊息
    _history.add(OllamaMessage(role: 'assistant', content: content));

    return (content: content, toolsUsed: usedToolNames);
  }

  /// 回覆很短、像在說「要做什麼」而不是答案（例如「查詢訂單清單」）
  static bool _looksLikeIntentOnly(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 20) return false;
    if (t.contains('？') || t.contains('?')) return false;
    return RegExp(r'(查詢|查|建立|下單|搜尋|找|列出|取得)').hasMatch(t);
  }

  /// 模型的回覆是否已經包含這段內容（逐行比對，忽略很短的行）
  static bool _alreadyContains(String reply, String block) {
    final lines = block
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[*\s\-#]'), ''))
        .where((l) => l.length >= 6)
        .toList();
    if (lines.isEmpty) return false;
    final flat = reply.replaceAll(RegExp(r'[*\s\-#]'), '');
    final hit  = lines.where(flat.contains).length;
    return hit >= (lines.length * 0.7).ceil();
  }

  /// 使用者按「確認建立」：直接用摘要當時的參數正式建立（不經過模型，避免模型改掉參數）
  Future<({String content, List<({String label, String url})> links})>
      confirmPendingOrder() async {
    final args = _pendingOrderArgs;
    if (args == null) {
      return (
        content: '目前沒有待確認的訂單，請重新下單。',
        links: const <({String label, String url})>[],
      );
    }
    final trace = _trace = ReasoningTrace();
    trace.add(TraceKind.input, '使用者按下「確認建立」');
    progress.value = '建立訂單中…';
    try {
      final callArgs = <String, dynamic>{...args, 'confirmed': true};
      trace.add(TraceKind.toolCall, '呼叫 MCP 工具「quick_order」（確認建立）',
          detail: '參數：${const JsonEncoder.withIndent('  ').convert(callArgs)}');
      final result   = await _mcp.callToolAsync('quick_order', callArgs);
      final contents = (result?.content ?? <ToolContent>[])
          .where((c) => c.type == 'text')
          .toList();
      final forUser = contents
          .where((c) => c.isForUser)
          .map((c) => (c.text ?? '').trim())
          .where((t) => t.isNotEmpty)
          .join('\n\n');
      final all    = contents.map((c) => c.text ?? '').join('\n').trim();
      final failed = result == null || result.isError == true;
      final content = failed
          ? '⚠️ 建立失敗：${all.isEmpty ? '伺服器沒有回應' : all}'
          : (forUser.isNotEmpty ? forUser : all);
      if (!failed) _pendingOrderArgs = null;
      trace.add(failed ? TraceKind.error : TraceKind.answer,
          failed ? '建立失敗' : '建立完成', detail: _clip(content));
      _lastActionLinks = failed ? const [] : extractMarkdownLinks(content);
      _history.add(OllamaMessage(role: 'assistant', content: content));
      return (content: content, links: _lastActionLinks);
    } catch (e) {
      trace.add(TraceKind.error, '建立失敗', detail: '$e');
      rethrow;
    } finally {
      progress.value = null;
    }
  }

  /// 目前待確認的訂單參數（給「修改」開網頁編輯頁用）；沒有就是 null
  Map<String, dynamic>? get pendingOrderArgs =>
      _pendingOrderArgs == null ? null : Map<String, dynamic>.from(_pendingOrderArgs!);

  /// 使用者在網頁改完訂單：用新內容重新產生摘要（不經過模型，也不會建立訂單）。
  /// 摘要正常 → 變成新的待確認訂單（有「確認建立」「修改」按鈕）；
  /// 摘要說缺規格等 → 回傳工具的說明，不是待確認狀態。
  Future<({String content, bool pending})> reviewEditedOrder(
      Map<String, dynamic> args) async {
    final trace = _trace = ReasoningTrace();
    trace.add(TraceKind.input, '使用者在網頁修改了訂單');
    progress.value = '重新產生訂單摘要…';
    try {
      final callArgs = Map<String, dynamic>.from(args)..remove('confirmed');
      trace.add(TraceKind.toolCall, '呼叫 MCP 工具「quick_order」（只產生摘要）',
          detail: '參數：${const JsonEncoder.withIndent('  ').convert(callArgs)}');
      final result   = await _mcp.callToolAsync('quick_order', callArgs);
      final contents = (result?.content ?? <ToolContent>[])
          .where((c) => c.type == 'text')
          .toList();
      final forUser = contents
          .where((c) => c.isForUser)
          .map((c) => (c.text ?? '').trim())
          .where((t) => t.isNotEmpty)
          .join('\n\n');
      final all    = contents.map((c) => c.text ?? '').join('\n').trim();
      final failed = result == null || result.isError == true;
      final ok     = !failed && forUser.contains('新訂單摘要');
      final content = failed
          ? '⚠️ 產生摘要失敗：${all.isEmpty ? '伺服器沒有回應' : all}'
          : (forUser.isNotEmpty ? forUser : all);
      _pendingOrderArgs      = ok ? callArgs : null;
      _lastReplyPendingOrder = ok;
      _lastActionLinks       = const [];
      trace.add(ok ? TraceKind.answer : TraceKind.warning,
          ok ? '新的訂單摘要' : '摘要不完整或失敗', detail: _clip(content));
      _history.add(OllamaMessage(role: 'assistant', content: content));
      return (content: content, pending: ok);
    } finally {
      progress.value = null;
    }
  }

  // ── 清除對話（保留 system prompt）────────────────────
  void clearHistory() {
    _history.removeWhere((m) => m.role != 'system');
    _pendingOrderArgs = null;
  }

  // ── 對話分支：存下／還原某一刻的對話狀態 ─────────────
  /// 目前的對話紀錄（不含 system）與待確認的訂單，編輯舊訊息開分支時用
  ChatSnapshot snapshot() => ChatSnapshot(
        _history.where((m) => m.role != 'system').toList(),
        _pendingOrderArgs == null
            ? null
            : Map<String, dynamic>.from(_pendingOrderArgs!),
      );

  /// 退回某個 snapshot。system prompt 保留（每次送出前本來就會重建）
  void restore(ChatSnapshot s) {
    _history.removeWhere((m) => m.role != 'system');
    _history.addAll(s.messages);
    _pendingOrderArgs = s.pendingOrderArgs == null
        ? null
        : Map<String, dynamic>.from(s.pendingOrderArgs!);
    _lastReplyPendingOrder = false;
  }

  List<OllamaMessage> get history => List.unmodifiable(_history);

  /// 工具的中文顯示名稱：取 MCP 工具說明的第一句（例如「查詢龍美系統櫃訂單」），
  /// 說明不是中文或找不到工具時，退回原本的程式名稱
  String toolDisplayName(String toolName) {
    final matched = _allTools.where((t) => t.function.name == toolName);
    if (matched.isEmpty) return toolName;
    var desc = (matched.first.function.description ?? '').trim();
    desc = desc.replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), ''); // 去掉多台 MCP 時加的 [Server 名稱]
    if (!RegExp(r'[一-鿿]').hasMatch(desc)) return toolName;
    final first = desc.split(RegExp(r'[（(，,。.；;：:\n]')).first.trim();
    if (first.isEmpty) return toolName;
    return first.length > 16 ? '${first.substring(0, 16)}…' : first;
  }
  SkillModel?         get currentSkill => _currentSkill;
}
