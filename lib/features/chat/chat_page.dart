import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:avatar_glow/avatar_glow.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/chat_orchestrator.dart';
import '../../services/connectivity_service.dart';
import '../../services/skill_store.dart';
import '../../models/skill_model.dart';
import '../../models/reasoning_trace.dart';
import '../../core/utils/link_launcher.dart';
import 'debug_test_input.dart';
import '../cabinet/cabinet_sync.dart';
import '../cabinet/wall.dart';
import '../../services/web_session.dart';
import '../cabinet/cabinet_web_controller.dart';
import '../cabinet/cabinet_draft_flow.dart';
import '../cabinet/dock_region.dart';
import '../cabinet/layout_message.dart';
import '../../core/config/app_config.dart';
import '../../voice/voice_orchestrator.dart';
import '../../voice/mobile_voice_output.dart';
import '../../voice/voice_mode.dart';
import '../../voice/voice_settings.dart';
import 'conversation_settings_sheet.dart';
import 'simple_style.dart';

// ── 訊息資料模型 ──────────────────────────────────────────
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime time;
  final List<String> toolsUsed; // ✅ Layer 6：記錄本則回應使用的工具
  final ReasoningTrace? trace; // 推理流程（AI 回覆才有）
  final bool isError;

  /// 工具給的待辦連結（例如詢單頁），訊息下方會顯示成按鈕
  final List<({String label, String url})> actionLinks;

  /// 這則是新訂單摘要，等使用者按「確認建立」
  final bool pendingOrder;

  /// 這則是「已成功建立正式訂單」的回覆（編輯更早的訊息前會提醒，訂單不會被撤銷）
  final bool orderCreated;

  /// 這則 AI 回覆要求使用者從目錄挑選櫃子（挑選畫面被關掉時，可以從這則重新打開）
  final bool pickRequested;
  final Map<String, dynamic>? pickPreselect; // 當時給挑選畫面的預選／候選內容

  /// 送出這則使用者訊息之前的對話狀態；有值才能長按編輯（編輯 = 退回這個狀態重送）
  ChatSnapshot? before;

  /// 這個位置被編輯過才有：同一位置的所有版本，可以用 ‹ › 切換
  BranchGroup? branch;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.toolsUsed = const [],
    this.trace,
    this.isError = false,
    this.actionLinks = const [],
    this.pendingOrder = false,
    this.orderCreated = false,
    this.pickRequested = false,
    this.pickPreselect,
    this.before,
  }) : time = DateTime.now();
}

/// 一個分支版本：從使用者那則訊息開始，到這個版本對話的結尾
class BranchVersion {
  List<ChatMessage> msgs;
  ChatSnapshot? end; // 離開這個版本時的對話狀態，切回來時還原
  BranchVersion(this.msgs);
}

/// 同一個位置（同一則使用者訊息）的所有編輯版本
class BranchGroup {
  final ChatSnapshot start; // 這則訊息送出前的對話狀態
  final List<BranchVersion> versions = [];
  int active = 0;
  BranchGroup(this.start);
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];

  /// 從目錄挑選、還沒送出的櫃子（輸入列上方的小標籤）
  final List<PickedItem> _picked = [];

  /// 已選櫃子清單展開／縮起（聊天與簡易模式共用）；新選了櫃子會自動展開
  bool _pickedExpanded = true;

  /// 口述中：說話的文字即時填進輸入框；_dictBase 是開始說話前輸入框原本的文字
  bool _dictating = false;
  String _dictBase = '';

  /// 正在編輯的使用者訊息（長按觸發）；送出時會開新分支
  ChatMessage? _editing;
  String _draftBeforeEdit = ''; // 進入編輯前輸入框原本的字，取消時還原
  bool _editByVoice = false; // 編輯方式：true = 語音重說、false = 修改文字

  bool _isLoading = false;
  bool _isRecording = false;
  bool _voiceAvailable = false;
  bool _isSpeaking = false;
  String _heardText = ''; // 簡易模式對話泡泡：聽到的話
  // AI 回答字幕：唸到哪顯示到哪
  String _replyText = '';
  double _replyShown = 0;
  bool _gotTtsProgress = false;
  Timer? _revealTimer;
  // 說話音量（0 ~ 1），水波紋跟著放大縮小；用 ValueNotifier 避免整頁重建
  final _micLevel = ValueNotifier<double>(0);
  bool _ttsEnabled     = true;  // 語音回覆開關（右上角音量按鈕），會記住
  static const _kTtsEnabled = 'tts_enabled';
  bool _simpleMode = false; // 左滑／右滑或點標題切換；兩個畫面共用同一份對話與選好的櫃子
  SimpleStyle _simpleStyle = SimpleStyle.classic; // 簡易模式的畫面風格（對話設定裡選）
  final PageController _pager = PageController(initialPage: 1);

  late final ChatOrchestrator _chat;
  late final VoiceOrchestrator _voice;
  late final ConnectivityService _connectivity;
  late final AppConfig _config;
  late final SkillStore _skillStore;

  @override
  void initState() {
    super.initState();
    _chat = GetIt.instance<ChatOrchestrator>();
    _voice = GetIt.instance<VoiceOrchestrator>();
    _connectivity = GetIt.instance<ConnectivityService>();
    _config = GetIt.instance<AppConfig>();
    _skillStore = GetIt.instance<SkillStore>();

    _connectivity.addListener(_onConnectivityChanged);
    _connectivity.start(); // 右上角燈號：定時檢查 AI 模型連線
    _skillStore.addListener(_onSkillChanged);
    _chat.progress.addListener(_onProgress);
    // 配置頁裡的櫃子被加、刪、改（尺寸／規格）→ 更新已選清單。
    // 這邊直接改清單、不再同步回配置頁（網頁本來就是這個狀態）
    GetIt.instance<CabinetWebController>().onCabinetsChanged = (items) {
      if (!mounted) return;
      setState(() {
        _picked
          ..clear()
          ..addAll(items);
      });
      // 使用者在配置頁改了：背景頁也要重算預設值與報價
      unawaited(_quote.syncBackground(List.of(_picked)));
    };
    // 配置畫面按「發送到聊天」：把排好的櫃子（含位置）組成一則訊息送進聊天
    GetIt.instance<CabinetWebController>().onSendToChat = _onSendToChat;
    _quote.onSynced = _onQuoteSynced;
    _quote.addListener(_onQuoteChanged);
    // 除錯版才有：自動化測試用的輸入口（可輸入中文），release 不會啟用
    if (kDebugMode) {
      _testInputTimer = startTestInputWatcher(
        isMounted: () => mounted,
        onFill: (t) => _ctrl.value = TextEditingValue(
          text: t,
          selection: TextSelection.collapsed(offset: t.length),
        ),
        onSend: _send,
      );
    }

    _voice.onRecordingChanged = (rec) => setState(() => _isRecording = rec);
    _voice.onSpeakingChanged = (s) {
      if (!mounted) return;
      setState(() {
        _isSpeaking = s;
        if (!s) {
          _revealTimer?.cancel();
          _replyShown = _replyText.length.toDouble();
        }
      });
    };
    _voice.onSpeakText = _startReveal;
    _loadTtsSetting();
    // 平滑一點，波紋才不會抖
    _voice.onMicLevel = (l) =>
        _micLevel.value = l == 0 ? 0 : _micLevel.value * 0.5 + l * 0.5;
    _voice.onSpeakProgress = (end) {
      if (!mounted) return;
      _gotTtsProgress = true;
      if (end > _replyShown) setState(() => _replyShown = end.toDouble());
    };
    _voice.onPartialTranscript = (text) {
      if (!mounted) return;
      setState(() => _heardText = text);
      if (_dictating && !GetIt.instance<CabinetWebController>().acceptsVoice) {
        _fillDictation(text);
      }
    };
    // 挑選／修改訂單的視窗開著時，講的話先交給網頁操作畫面（選規格、下一步、加入…）；
    // 網頁聽不懂的（放左牆、調順序、改客戶…）再交給 AI，對話能做的簡易語音也要能做
    _voice.interceptTranscript = (text) async {
      final c = GetIt.instance<CabinetWebController>();
      if (!c.acceptsVoice) return false;
      if (mounted) setState(() => _heardText = text);
      final r = await c.voiceCommand(text);
      return r['handled'] == true;
    };
    // 簡易模式語音直接送給 AI（不經過輸入框），一樣附上目前已選的櫃子與規格
    _voice.aiNoteProvider = () {
      if (_picked.isEmpty) return null;
      _sentPickedSig = pickedSignature(_picked);
      return _pickedNote();
    };
    _voice.onTranscribed = (text) {
      // 語音送出的訊息也能長按編輯（會記下送出前的對話狀態）；
      // 簡易模式長按某句選「語音重說」後，這次說的話會從那句開新分支
      setState(() => _heardText = text);
      _addUserMessage(ChatMessage(text: text, isUser: true));
      _scrollToBottom();
    };
    _voice.onResponse = (text) {
      setState(() {
        _messages.add(ChatMessage(
            text: text,
            isUser: false,
            trace: _chat.lastTrace,
            actionLinks: _chat.lastActionLinks,
            pickRequested: _chat.lastPickRequested,
            pickPreselect: _chat.lastPickPreselect,
            pendingOrder: _chat.lastReplyPendingOrder));
        _isLoading = false;
      });
      _scrollToBottom();
      // AI 要使用者從目錄挑選櫃子
      if (_chat.lastPickRequested) _openPicker(preselect: _chat.lastPickPreselect);
      // AI 判斷使用者想看畫面／介面
      if (_chat.lastOpenConfigRequested) _openConfigByAi();
      // 使用者用說的確認建立：照畫面上的摘要正式建立
      if (_chat.lastConfirmRequested) unawaited(_confirmOrder(spoken: true));
    };
    _voice.onError = (err) {
      setState(() => _isLoading = false);
      _showSnack(err, isError: true);
    };
    // 連續對話：一直沒開口就暫停
    _voice.onPaused = () {
      if (!mounted) return;
      setState(() => _heardText = '');
      _showSnack('${_voice.settings.idleSeconds} 秒沒講話，已暫停；點「你」繼續');
    };
    // AI 講話中聽到插話關鍵字：AI 已經停下來，改聽你說
    _voice.onBargeIn = () {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _heardText = '');
    };
    unawaited(VoiceConversationSettings.load().then((s) {
      _voice.settings = s;
      if (mounted) setState(() {});
    }));
    unawaited(SimpleStyleSpec.load().then((s) {
      if (mounted) setState(() => _simpleStyle = s);
    }));

    _voice.setMode(VoiceMode.pushToTalk);
    _initVoice();

    _chat.applySkill(_skillStore.activeSkill);

    _messages.add(ChatMessage(
      text: '您好！我是**隆美系統櫃助理** 🗄️\n\n請問有什麼可以幫您的嗎？\n\n您可以詢問：\n'
          '- 📦 查詢訂單狀態\n- 📋 查詢訂單明細\n'
          '- 🚚 確認交貨日期\n- 💰 查詢訂單金額',
      isUser: false,
    ));
  }

  // ── Skill 切換回調 ────────────────────────────────────
  void _onSkillChanged() {
    _chat.applySkill(_skillStore.activeSkill, force: true);
    if (mounted) setState(() {});
  }

  void _onConnectivityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initVoice() async {
    try {
      await _voice.initialize();
    } catch (_) {}
    final available = _voice.isReady;
    setState(() => _voiceAvailable = available);
    if (!available) _showVoiceFallbackBanner();
  }

  void _showVoiceFallbackBanner() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          leading: const Icon(Icons.mic_off_rounded, color: Colors.orange),
          backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          content: Text(
            '語音功能無法使用，請以文字輸入',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSecondaryContainer),
          ),
          actions: [
            TextButton(
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                _initVoice();
              },
              child: const Text('重試'),
            ),
            TextButton(
              onPressed: () =>
                  ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
              child: const Text('關閉'),
            ),
          ],
        ),
      );
    });
  }

  // ── 簡易模式 ──────────────────────────────────────────
  void _toggleSimpleMode() {
    HapticFeedback.selectionClick();
    // 切到簡易模式：先收起鍵盤（簡易模式沒有輸入框，鍵盤留著會擋住畫面）
    if (!_simpleMode) FocusManager.instance.primaryFocus?.unfocus();
    _pager.animateToPage(
      _simpleMode ? 1 : 0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// 左右滑動或點標題都會走到這裡（0＝簡易、1＝聊天）
  void _onPageChanged(int i) {
    final simple = i == 0;
    if (simple == _simpleMode) return;
    // 用滑的切到簡易模式也一樣收起鍵盤
    if (simple) FocusManager.instance.primaryFocus?.unfocus();
    // 離開簡易模式：連續對話也一起結束
    if (_voice.inLoop) unawaited(_voice.stopLoop());
    if (_isRecording) _voice.stopTurn();
    if (_isSpeaking) _voice.stopSpeaking();
    setState(() => _simpleMode = simple);
    _scrollToBottom();
  }

  // ── 語音回覆開關 ──────────────────────────────────────
  Future<void> _loadTtsSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getBool(_kTtsEnabled) ?? true;
      _voice.speakReplies = on;
      if (mounted) setState(() => _ttsEnabled = on);
      // 語速、音調、聲音
      await GetIt.instance<MobileVoiceOutput>().loadSettings();
    } catch (_) {}
  }

  /// 語音回覆開關
  Future<void> _setTtsEnabled(bool on) async {
    setState(() => _ttsEnabled = on);
    _voice.speakReplies = on;
    if (!on && _isSpeaking) await _voice.stopSpeaking(); // 關掉時正在唸的也停下來
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTtsEnabled, on);
    } catch (_) {}
  }

  /// 連續對話、停頓秒數、插話關鍵字（長按「你」或右上角選單）
  Future<void> _openConversationSettings() async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ConversationSettingsSheet(
        initial: _voice.settings,
        onChanged: (s) {
          _voice.settings = s;
          unawaited(s.save());
          if (mounted) setState(() {});
        },
        initialStyle: _simpleStyle,
        onStyleChanged: (st) {
          unawaited(SimpleStyleSpec.save(st));
          if (mounted) setState(() => _simpleStyle = st);
        },
      ),
    );
  }

  /// 右上角喇叭：語音設定小視窗（開關、語速、音調、聲音）
  void _openVoiceSettings() {
    showDialog(
      context: context,
      builder: (_) => _VoiceSettingsDialog(
        tts: GetIt.instance<MobileVoiceOutput>(),
        enabled: _ttsEnabled,
        onEnabledChanged: _setTtsEnabled,
      ),
    );
  }

  /// AI 開始唸：字幕從 0 開始。有 TTS 進度就跟著進度走，
  /// 平台沒有回報進度時，用估計的語速慢慢顯示
  void _startReveal(String text) {
    _revealTimer?.cancel();
    _gotTtsProgress = false;
    setState(() {
      _replyText = text;
      _replyShown = 0;
    });
    const tick = Duration(milliseconds: 100);
    const charsPerSecond = 5.0;
    var waited = Duration.zero;
    _revealTimer = Timer.periodic(tick, (t) {
      if (!mounted || _gotTtsProgress) return t.cancel();
      waited += tick;
      if (waited < const Duration(milliseconds: 500)) return; // 等看看有沒有進度
      if (_replyShown >= _replyText.length) return t.cancel();
      setState(() => _replyShown += charsPerSecond * tick.inMilliseconds / 1000);
    });
  }

  /// 大麥克風：閒置→開始聽；聽的時候→結束並送出；唸的時候→打斷
  Future<void> _onSimpleMicTap() async {
    if (_isLoading) return;
    if (_isSpeaking) {
      HapticFeedback.lightImpact();
      await _voice.stopSpeaking();
      return;
    }
    if (_isRecording) {
      HapticFeedback.lightImpact();
      // 連續對話中還沒開口就按：結束連續對話；已經在講：馬上送出這句
      if (_voice.settings.continuous && _heardText.trim().isEmpty) {
        await _voice.stopLoop();
        _showSnack('已結束連續對話；點「你」重新開始');
      } else {
        await _voice.stopTurn();
      }
      return;
    }
    HapticFeedback.mediumImpact();
    _revealTimer?.cancel();
    setState(() {
      _heardText = '';
      _replyText = '';
      _replyShown = 0;
    });
    await _voice.startTurn();
  }

  // ── 進度文字（例如「查詢龍美系統櫃訂單中…」）──────────
  String? _progress;
  void _onProgress() {
    if (mounted) setState(() => _progress = _chat.progress.value);
  }

  /// 最後一則是待確認的新訂單摘要 → 顯示「確認建立／修改」
  bool get _showOrderButtons =>
      !_isLoading &&
      _messages.isNotEmpty &&
      _messages.last.pendingOrder &&
      _chat.hasPendingOrder;

  /// 按「確認建立」：直接正式建立，不經過 AI
  /// [spoken]：使用者用說的確認（AI 判斷後交給 App）。說的這句已經是明確確認，不再跳確認視窗，
  /// 也不另外加「確認建立」的訊息（使用者說的那句已經在畫面上）。
  Future<void> _confirmOrder({bool spoken = false}) async {
    if (_isLoading || !_chat.hasPendingOrder) return;
    HapticFeedback.mediumImpact();
    // 建立後無法刪除：按按鈕的再確認一次，避免誤按
    final ok = spoken ? true : await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('建立正式案件？'),
        content: const Text('會建立正式案件編號，建立後無法刪除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('先不要'),
          ),
          FilledButton(
            // 淺色主題把 FilledButton 設成滿版寬，這裡指定一般寬度
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('確定建立'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      if (!spoken) _messages.add(ChatMessage(text: '確認建立', isUser: true));
      _isLoading = true;
    });
    _scrollToBottom();
    try {
      final (content: raw, :links) = await _chat.confirmPendingOrder();
      // 有「更新詢單」連結：App 會在背景自動存檔，不用使用者再開網頁（連結留著備用）
      final autoSave = !raw.startsWith('⚠️') &&
          links.any((l) => CabinetDraftFlow.parseLink(l.url) != null);
      final content = autoSave
          ? raw.replaceFirst('請點下面連結，在網頁確認價格後按「更新詢單」完成存檔：',
              '櫃子與價格會自動存進案件，不用開網頁（下面的連結留著備用）：')
          : raw;
      setState(() {
        _messages.add(ChatMessage(
          text: content,
          isUser: false,
          toolsUsed: const ['quick_order'],
          trace: _chat.lastTrace,
          actionLinks: links,
          isError: content.startsWith('⚠️'),
          orderCreated: !content.startsWith('⚠️'),
        ));
        _isLoading = false;
        // 訂單真的建立成功了，已選的櫃子才收掉
        if (!content.startsWith('⚠️')) {
          _picked.clear();
          _sentPickedSig = '';
        }
      });
      if (autoSave) {
        // 不唸「請點連結」那一大段，存檔結果出來會再唸一次
        _voice.speakReply('已建立案件，櫃子和價格正在自動存檔');
        unawaited(_autoSaveCabinets(links));
      } else {
        _voice.speakReply(content);
      }
      // 不自動開啟「更新詢單」連結（會突然彈出視窗、還可能停在登入畫面）；
      // 改在背景自動存檔，失敗時訊息下方的按鈕可以手動開
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(
          text: '⚠️ 建立失敗：${'$e'.replaceFirst('Exception: ', '')}',
          isUser: false,
          trace: _chat.lastTrace,
          isError: true,
        ));
        _isLoading = false;
      });
    }
    _scrollToBottom();
  }

  /// 建單成功後，把櫃子與價格自動存進案件：在看不見的背景配置頁載入案件、
  /// 套入櫃子、算好價格後直接「更新詢單」，不用再點連結到網頁按。
  /// 失敗就照實說，並留下連結按鈕讓使用者手動開。
  Future<void> _autoSaveCabinets(List<({String label, String url})> links) async {
    final targets = [
      for (final l in links)
        if (CabinetDraftFlow.parseLink(l.url) != null) l
    ];
    if (targets.isEmpty) return;
    final flow = GetIt.instance<CabinetDraftFlow>();
    final bg = GetIt.instance<CabinetWebController>(instanceName: 'quote');
    setState(() => _messages.add(ChatMessage(
        text: '櫃子與價格存檔中（約 1 分鐘，不用開畫面）…', isUser: false)));
    _scrollToBottom();
    final lines = <String>[];
    final failed = <({String label, String url})>[];
    for (final l in targets) {
      final r = await flow.autoSave(l.url, bg);
      if (r == null) continue;
      if (r.ok) {
        lines.add('✅ ${l.label}：已存進案件'
            '${r.price != null ? '，NT\$ ${_PickedPanel._money(r.price!)}' : ''}');
      } else {
        failed.add(l);
        lines.add('⚠️ ${l.label}：自動存檔失敗（${r.message}），'
            '請按下面的按鈕到網頁按「更新詢單」');
      }
    }
    if (!mounted || lines.isEmpty) return;
    setState(() => _messages.add(ChatMessage(
          text: lines.join('\n\n'),
          isUser: false,
          isError: failed.isNotEmpty,
          actionLinks: failed,
        )));
    _scrollToBottom();
    _voice.speakReply(failed.isEmpty
        ? '櫃子和價格已經存進案件'
        : '自動存檔失敗，請按按鈕到網頁更新詢單');
  }

  /// 按「修改」：輸入框帶入「我要修改：」，說完重新產生摘要
  void _editOrder() => unawaited(_editOrderViaWeb());

  /// 按「修改」：在視窗裡開網頁編輯頁（客戶資料、空間、每顆櫃子的規格都能直接改），
  /// 按「套用修改」後用新內容重新產生訂單摘要，再讓使用者確認
  Future<void> _editOrderViaWeb() async {
    if (_isLoading) return;
    final args = _chat.pendingOrderArgs;
    if (args == null) {
      _showSnack('目前沒有待確認的訂單');
      return;
    }
    final edited = await GetIt.instance<CabinetWebController>().editOrder(args);
    if (!mounted || edited == null) return; // 關掉視窗 = 不改
    setState(() => _isLoading = true);
    try {
      final r = await _chat.reviewEditedOrder(edited);
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          text: r.content,
          isUser: false,
          toolsUsed: const ['quick_order'],
          trace: _chat.lastTrace,
          pendingOrder: r.pending,
          isError: r.content.startsWith('⚠️'),
        ));
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          text: '⚠️ 修改失敗：${'$e'.replaceFirst('Exception: ', '')}',
          isUser: false,
          trace: _chat.lastTrace,
          isError: true,
          pendingOrder: _chat.hasPendingOrder,
        ));
        _isLoading = false;
      });
    }
    _scrollToBottom();
  }

  // ── 傳送訊息（Layer 6：解構 Record）─────────────────
  /// 上一次送給 AI 的已選清單指紋。送出後清單會留在畫面上（直到訂單真的建立成功，
  /// 或使用者自己刪掉），靠這個判斷「有沒有新的變動還沒送」
  String _sentPickedSig = '';

  /// 已選清單有還沒送給 AI 的內容（新加、刪除、改數量或規格之後）
  bool get _pickedUnsent =>
      _picked.isNotEmpty && pickedSignature(_picked) != _sentPickedSig;

  /// 只給模型看的「目前已選的櫃子」（品號、數量、規格參數、還沒選的項目）
  String _pickedNote() => '目前已選的櫃子（畫面上已經選好，不用再問品號與規格）：\n'
      '${_picked.map((p) => '- ${p.forAi}').join('\n')}';

  /// 輸入框的字 + 挑選的櫃子，組成要送給 AI 的一句話
  String _compose(String text) {
    final t = text.trim();
    // 清單沒變動（已經送給 AI 過）就不重複附上，否則每則訊息都會夾帶一份一樣的清單
    if (!_pickedUnsent) return t;
    final picked = '我選的櫃子：\n${_picked.map((p) => '- ${p.forAi}').join('\n')}';
    return t.isEmpty ? picked : '$t\n$picked';
  }

  /// 口述：把說話的文字接在原本的輸入框文字後面
  void _fillDictation(String spoken) {
    final base = _dictBase;
    final needSep = base.isNotEmpty && !base.endsWith(' ') && !base.endsWith('\n');
    final full = '$base${needSep ? ' ' : ''}$spoken';
    _ctrl.value = TextEditingValue(
      text: full,
      selection: TextSelection.collapsed(offset: full.length),
    );
  }

  /// 彈出產品挑選畫面。聊天模式：選的櫃子變成輸入列上的標籤，讓使用者確認後再送出；
  /// 簡易模式（單手語音操作）：直接當成使用者說的話送出。
  Future<void> _openPicker({Map<String, dynamic>? preselect}) async {
    final items = await _pickWithCollapse(preselect: preselect);
    if (!mounted || items == null || items.isEmpty) return;
    setState(() {
      _pickedExpanded = true; // 剛選好的要讓使用者看到
      for (final it in items) {
        final i = _picked.indexWhere((p) => p.sameAs(it));
        if (i >= 0) {
          _picked[i] = _picked[i].withQuantity(_picked[i].quantity + it.quantity);
        } else {
          _picked.add(it);
        }
      }
    });
    _syncPickedToConfig();
  }

  Timer? _testInputTimer; // 除錯版的測試輸入口（見 debug_test_input.dart）

  /// 已選的櫃子有變動：配置頁開著的話同步進去（沒開就什麼都不做），
  /// 同時交給看不見的背景配置頁，算網站實際的預設規格值和報價
  void _syncPickedToConfig() {
    unawaited(GetIt.instance<CabinetWebController>()
        .syncCabinets(List.of(_picked)));
    unawaited(_quote.syncBackground(List.of(_picked)));
  }

  // ── 背景配置頁：預設值與報價 ──
  void _onQuoteChanged() {
    if (mounted) setState(() {}); // 價格、試算狀態變了，重畫標題列
  }

  CabinetWebController get _quote =>
      GetIt.instance<CabinetWebController>(instanceName: 'quote');

  /// 背景頁算的是哪一份已選清單（跟目前的清單比，不一樣代表還沒算完）
  String _quoteSig = '';

  /// 背景頁同步完：用網站實際的規格值（含預設）更新已選卡片。
  /// 直接改清單、不再觸發同步（值本來就是網站算出來的）
  void _onQuoteSynced(List<PickedItem> synced, Map<String, PickedItem> sources,
      List<ConfigCabinet> cabinets) {
    if (!mounted) return;
    final r = applyResolved(
        current: _picked, synced: synced, sources: sources, cabinets: cabinets);
    setState(() {
      _quoteSig = pickedSignature(synced);
      if (r.changed) {
        _picked
          ..clear()
          ..addAll(r.items);
      }
    });
  }

  /// 標題列要顯示的報價狀態：busy＝試算中；price＝金額（資料齊全且是目前這份清單才有）
  ({num? price, bool busy}) get _quoteView {
    if (_picked.isEmpty) return (price: null, busy: false);
    final working = _quote.syncBusy;
    final fresh = _quoteSig == pickedSignature(_picked);
    final price = _quote.price;
    final ok = !working &&
        fresh &&
        _picked.every((p) => p.verified) &&
        price != null &&
        price > 0;
    return (price: ok ? price : null, busy: working || (!fresh && _quote.isOpen && _quote.error == null));
  }

  /// 開挑選網頁。網頁開著時把下面「已選品項」縮成一條，讓上面的網頁視窗有更多空間；
  /// 關掉後恢復原本的展開狀態（有選到新東西時，呼叫端會再展開讓使用者看到）
  int _pickToken = 0; // 最後一次開啟才負責恢復（舊的被新的取代時不要誤恢復）
  bool? _expandedBeforePick; // 開網頁前「已選品項」是不是展開的

  Future<List<PickedItem>?> _pickWithCollapse(
      {Map<String, dynamic>? preselect}) async {
    final token = ++_pickToken;
    _expandedBeforePick ??= _pickedExpanded;
    if (_picked.isNotEmpty && mounted) {
      setState(() => _pickedExpanded = false);
    }
    try {
      return await GetIt.instance<CabinetWebController>()
          .pickProducts(preselect: preselect);
    } finally {
      if (token == _pickToken) {
        final was = _expandedBeforePick ?? true;
        _expandedBeforePick = null;
        if (mounted) setState(() => _pickedExpanded = was);
      }
    }
  }

  /// 點已選的某個櫃子：開網頁並跳到「填規格」那一步（帶著目前的規格），
  /// 填好按「加入」後取代原本那一張；關掉視窗就不改
  Future<void> _editPicked(PickedItem p) async {
    if (_isLoading) return;
    final items = await _pickWithCollapse(
      preselect: {
        'items': [
          {'productNo': p.productNo, 'quantity': p.quantity, 'specs': p.specs},
        ],
        'autoAdd': false, // 一定停在規格頁，由使用者按「加入」
      },
    );
    if (!mounted || items == null || items.isEmpty) return;
    setState(() {
      // 取代原本那一張；改完跟別張一樣（同產品同規格）就合併數量
      final next = <PickedItem>[];
      void addMerged(PickedItem it) {
        final j = next.indexWhere((x) => x.sameAs(it));
        if (j >= 0) {
          next[j] = next[j].withQuantity(next[j].quantity + it.quantity);
        } else {
          next.add(it);
        }
      }

      var replaced = false;
      for (final x in _picked) {
        if (identical(x, p)) {
          items.forEach(addMerged);
          replaced = true;
        } else {
          addMerged(x);
        }
      }
      if (!replaced) items.forEach(addMerged); // 編輯期間這張被刪掉了：當成新增
      _picked
        ..clear()
        ..addAll(next);
      _pickedExpanded = true;
    });
    _syncPickedToConfig();
  }

  /// 最後一則 AI 回覆如果是「請挑選櫃子」，回傳「重新開啟挑選畫面」的動作
  /// （不小心把挑選畫面關掉時用）；其他情況回傳 null
  VoidCallback? _reopenPickerFor(int i) {
    if (_isLoading || i != _messages.length - 1) return null;
    final m = _messages[i];
    if (m.isUser || !m.pickRequested) return null;
    return () => unawaited(_openPicker(preselect: m.pickPreselect));
  }

  /// 已選的櫃子還有規格沒跟網站核對（背景正在試算）：先等算完再送。
  /// 沒預設值的規格（開門方向、上固隔）要靠背景頁算出實際值，AI 才帶得出完整規格；
  /// 不等的話伺服器會回「缺少以下規格」，AI 又回頭問你。背景頁不可用或失敗就不等。
  Future<void> _waitForPickedDefaults() async {
    bool pending() => _picked.any((p) => !p.verified);
    if (!_pickedUnsent || !pending()) return;
    if (!_quote.isOpen || _quote.error != null || !_quote.syncBusy) return;
    // 沒記下登入帳密＝背景網頁會停在登入畫面，等也算不出來，直接送
    if (GetIt.instance<WebSession>().credentials == null) return;
    setState(() {
      _isLoading = true;
      _progress = '確認規格預設值中…';
    });
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (mounted && DateTime.now().isBefore(end) && pending() && _quote.syncBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _progress = null;
    });
  }

  /// AI 判斷使用者想看畫面／介面，呼叫了 MCP 的 open_config_view 工具：
  /// 打開系統櫃配置網頁（已選的櫃子一起帶進去），並收起螢幕鍵盤（不然會擋住網頁）。
  /// 是否要開由 AI 決定，這裡只負責執行。
  void _openConfigByAi() {
    // AI 要把已選的櫃子換牆（「移到右邊」）：先改已選清單，再開畫面重新擺放
    // 一輪可能有好幾個動作（每個櫃子各一面牆／各一個順序），依序套用
    final moves = List<Map<String, String?>>.of(_chat.lastMoves);
    // 這次沒帶任何動作：已選櫃子都還沒指定牆，就沿用下單時使用者說的那面牆
    final ow = _chat.lastOrderWall;
    if (moves.isEmpty && ow != null && _picked.isNotEmpty && _picked.every((p) => p.wall == null)) {
      moves.add({'wall': ow, 'productNo': null});
    }
    if (moves.isNotEmpty) {
      var next = List.of(_picked);
      for (final mv in moves) {
        final pos = int.tryParse(mv['position'] ?? '');
        // 調順序時，網頁不能把「同樣組成」的櫃子還原回舊位置，要照新順序重排
        if (pos != null) GetIt.instance<CabinetWebController>().relayoutOnNextSync = true;
        next = movePicked(next,
            wall: mv['wall'],
            productNo: mv['productNo'],
            position: pos,
            count: int.tryParse(mv['count'] ?? ''));
      }
      setState(() => _picked
        ..clear()
        ..addAll(next));
    }
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _openCabinetConfig();
  }

  /// 打開系統櫃配置畫面：已選的櫃子一起帶進去，對話裡的客戶名稱預填到「建立詢單」
  void _openCabinetConfig() {
    final web = GetIt.instance<CabinetWebController>();
    final customer = _chat.lastCustomer;
    web.prefillOrderInfo = customer == null ? null : {'Customer': customer};
    unawaited(web.openNew(cabinets: List.of(_picked)));
  }

  /// 配置畫面按「發送到聊天」：櫃子排列（含位置）和填的欄位變成一則使用者訊息送給 AI。
  /// AI 正在回覆時不硬插隊，改放進輸入框讓使用者自己按送出。
  void _onSendToChat(Map<String, dynamic> data) {
    if (!mounted) return;
    // 使用者看到的：誰是第幾個。座標、牆面、規格參數只放在給模型的備註裡
    final text = composeLayoutMessage(data);
    final note = composeLayoutAiNote(data);
    // 使用者在網頁拖過牆面：記回已選清單，之後重新打開配置頁才會還原在同一面牆
    final cabs = data['cabinets'];
    if (cabs is List) {
      final next = applyWallsFromLayout(_picked, cabs);
      setState(() => _picked
        ..clear()
        ..addAll(next));
    }
    // 訊息裡已經列了櫃子，不要再附一份「我選的櫃子」
    _sentPickedSig = pickedSignature(_picked);
    if (_isLoading) {
      _pendingAiNote = note.isEmpty ? null : note;
      _ctrl.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      return;
    }
    unawaited(_send(text, aiNote: note.isEmpty ? null : note));
  }

  /// 「發送到聊天」時放不進去（AI 正在回覆）而暫存的、只給模型看的配置備註；下一次送出時帶上
  String? _pendingAiNote;

  /// 加入使用者送出的訊息並進入等待。正在編輯舊訊息（[_editing]）時開新分支：
  /// 舊的後續對話整段存起來，AI 的歷史退回那則送出前。打字送出和簡易模式語音都走這裡。
  void _addUserMessage(ChatMessage newMsg) {
    final editing = _editing;
    final idx = editing == null ? -1 : _messages.indexOf(editing);
    if (editing != null && idx >= 0) {
      var group = editing.branch;
      if (group == null) {
        group = BranchGroup(editing.before!)..versions.add(BranchVersion([]));
        editing.branch = group;
      }
      final cur = group.versions[group.active];
      cur.msgs = _messages.sublist(idx);
      cur.end = _chat.snapshot();
      group.versions.add(BranchVersion([newMsg]));
      group.active = group.versions.length - 1;
      newMsg.branch = group;
      newMsg.before = group.start;
      _chat.restore(group.start);
    } else {
      newMsg.before = _chat.snapshot();
    }
    setState(() {
      if (editing != null && idx >= 0) _messages.removeRange(idx, _messages.length);
      _editing = null;
      _draftBeforeEdit = '';
      _messages.add(newMsg);
      _isLoading = true;
    });
  }

  Future<void> _send(String text, {String? aiNote}) async {
    if (_isLoading) return;
    // 只給模型看的備註：這次沒指定就用暫存的（只帶一次）
    aiNote ??= _pendingAiNote;
    _pendingAiNote = null;
    await _waitForPickedDefaults();
    if (!mounted) return;
    // 清單有新變動時會直接附在訊息裡（畫面上看得到）；沒變動時改用「只給模型看的備註」附上，
    // 這樣每一輪 AI 都知道目前選了哪些櫃子，不會因為清單沒進到它的記憶就一直反問
    final listInMessage = _pickedUnsent;
    final trimmed = _compose(text);
    if (trimmed.isEmpty) return;
    if (_picked.isNotEmpty && !listInMessage) {
      final cur = _pickedNote();
      aiNote = (aiNote == null || aiNote.isEmpty) ? cur : '$aiNote\n$cur';
    }
    _ctrl.clear();
    // 已選的櫃子送出後不清掉（要等訂單真的建立成功，或使用者自己刪除），只記下這份已送出
    _sentPickedSig = pickedSignature(_picked);

    _addUserMessage(ChatMessage(text: trimmed, isUser: true));
    _scrollToBottom();

    try {
      final (:content, :toolsUsed) =
          await _chat.sendMessageAsync(trimmed, aiNote: aiNote);
      setState(() {
        _messages.add(ChatMessage(
          text: content,
          isUser: false,
          toolsUsed: toolsUsed, // ✅ 傳入工具清單
          trace: _chat.lastTrace,
          actionLinks: _chat.lastActionLinks,
          pickRequested: _chat.lastPickRequested,
          pickPreselect: _chat.lastPickPreselect,
          pendingOrder: _chat.lastReplyPendingOrder,
        ));
        _isLoading = false;
      });
      // 打字送出也用語音唸出回覆（右上角音量按鈕可以關掉）；不等唸完
      _voice.speakReply(content);
      // 工具給的待辦連結（例如詢單頁）不自動開啟，訊息下方有按鈕，要看再按
      // AI 要使用者從目錄挑選櫃子
      if (_chat.lastPickRequested) {
        unawaited(_openPicker(preselect: _chat.lastPickPreselect));
      }
      // AI 判斷使用者想看畫面／介面：開系統櫃配置網頁並收鍵盤
      if (_chat.lastOpenConfigRequested) _openConfigByAi();
      // 使用者說「確認建立」：照畫面上的摘要正式建立
      if (_chat.lastConfirmRequested) unawaited(_confirmOrder(spoken: true));
    } catch (e) {
      // 失敗也留一則訊息，方便打開推理過程看卡在哪一步
      setState(() {
        _messages.add(ChatMessage(
          text: '⚠️ 發生錯誤：${'$e'.replaceFirst('Exception: ', '')}',
          isUser: false,
          trace: _chat.lastTrace,
          isError: true,
        ));
        _isLoading = false;
      });
    }
    _scrollToBottom();
  }

  // ── 對話分支：長按自己的訊息編輯、用 ‹ › 切換版本 ─────
  bool _canEdit(ChatMessage m) =>
      m.isUser && m.before != null && !_isLoading && !_isRecording;

  /// 長按使用者訊息：先選要「語音重說」還是「修改文字」
  Future<void> _chooseEditMode(ChatMessage msg) async {
    if (!_canEdit(msg)) return;
    HapticFeedback.mediumImpact();
    final voice = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.edit_rounded),
            title: const Text('修改文字'),
            subtitle: Text(_simpleMode
                ? '切到聊天模式，原文帶進輸入框修改'
                : '原文帶進輸入框，用打字修改'),
            onTap: () => Navigator.pop(ctx, false),
          ),
          ListTile(
            enabled: _voiceAvailable,
            leading: const Icon(Icons.mic_rounded),
            title: const Text('語音重說'),
            subtitle: Text(!_voiceAvailable
                ? '語音功能不可用'
                : _simpleMode
                    ? '點「你」重新說這一句，之後的對話會重來'
                    : '清空輸入框，長按麥克風重新說一次'),
            onTap: _voiceAvailable ? () => Navigator.pop(ctx, true) : null,
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (voice == null || !mounted) return;
    // 簡易模式沒有輸入框：修改文字就切到聊天模式帶入原文；語音重說留在簡易模式，點「你」重說
    if (_simpleMode && !voice) _toggleSimpleMode();
    await _startEdit(msg, voice: voice);
  }

  /// 進入編輯：文字模式帶入原文；語音模式清空，等使用者長按麥克風重說。
  /// 送出後在這個位置開新分支
  Future<void> _startEdit(ChatMessage msg, {bool voice = false}) async {
    if (!_canEdit(msg)) return;
    final idx = _messages.indexOf(msg);
    if (idx < 0) return;
    // 後面已經建立過正式訂單：訂單在 ERP 裡，編輯不會撤銷，先提醒
    if (_messages.skip(idx).any((m) => m.orderCreated)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('這之後已建立過訂單'),
          content: const Text(
              '後面的對話裡已經建立了正式訂單。編輯只會開新分支，已建立的訂單不會被撤銷。\n\n要繼續編輯嗎？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('先不要')),
            FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('繼續編輯')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (!_canEdit(msg) || !_messages.contains(msg)) return; // 等待期間狀態變了
    }
    HapticFeedback.mediumImpact();
    setState(() {
      if (_editing == null) _draftBeforeEdit = _ctrl.text;
      _editing = msg;
      _editByVoice = voice;
      final t = voice ? '' : msg.text;
      _ctrl.value = TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(offset: t.length),
      );
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing = null;
      _ctrl.text = _draftBeforeEdit;
      _draftBeforeEdit = '';
    });
  }

  /// ‹ › 切換同一位置的版本；後面的對話、AI 的記憶、待確認訂單都跟著換
  void _switchBranch(ChatMessage head, int delta) {
    final group = head.branch;
    if (group == null || _isLoading || _isRecording) return;
    final next = group.active + delta;
    if (next < 0 || next >= group.versions.length) return;
    final idx = _messages.indexOf(head);
    if (idx < 0) return;
    if (_isSpeaking) _voice.stopSpeaking();

    final cur = group.versions[group.active];
    cur.msgs = _messages.sublist(idx);
    cur.end = _chat.snapshot();
    group.active = next;
    final target = group.versions[next];
    setState(() {
      if (_editing != null) {
        _editing = null;
        _ctrl.text = _draftBeforeEdit;
        _draftBeforeEdit = '';
      }
      _messages.removeRange(idx, _messages.length);
      _messages.addAll(target.msgs);
      // AI 的記憶換成那個版本的了：已選清單那個版本不一定送過，當成還沒送，下一則會再附上
      _sentPickedSig = '';
    });
    if (target.end != null) _chat.restore(target.end!);
    _scrollToBottom();
  }

  void _showQuickCommands() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _QuickCommandSheet(onSelected: (cmd) {
        Navigator.pop(context);
        _send(cmd);
      }),
    );
  }

  void _showSkillPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // ✅ 必須加這行
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SkillPickerSheet(
        skillStore: _skillStore,
        onSelected: (skill) async {
          Navigator.pop(context);
          await _skillStore.setActiveSkill(skill);
          _showSnack('已切換至：${skill.icon} ${skill.name}');
        },
        onManage: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, '/skills');
        },
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
      }
    });
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  /// 清除 MCP 上的草稿（還沒存進案件的櫃子），結果用提示告訴使用者
  Future<void> _clearDrafts() async {
    final err = await _chat.clearDrafts();
    if (!mounted) return;
    if (err == null) {
      _showSnack('對話、已選的櫃子與草稿都已清除');
    } else {
      _showSnack('對話與已選的櫃子已清除，但草稿清除失敗：$err', isError: true);
    }
  }

  void _showClearDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded, size: 36),
        title: const Text('清除對話'),
        content: const Text('確定要清除嗎？\n'
            '對話記錄、已選的櫃子、還沒存進案件的草稿都會一起清掉，AI 從頭開始。\n'
            '（已經建立的正式案件不受影響）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () {
                _chat.clearHistory();
                _chat.applySkill(_skillStore.activeSkill);
                setState(() {
                  _messages.clear();
                  if (_editing != null) _ctrl.text = _draftBeforeEdit;
                  _editing = null;
                  _draftBeforeEdit = '';
                  // 已選的櫃子也一起清掉
                  _picked.clear();
                  _sentPickedSig = '';
                });
                _syncPickedToConfig();
                Navigator.pop(context);
                unawaited(_clearDrafts());
              },
              child: const Text('清除')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _connectivity.status as ConnectionStatus;
    final epName = _config.activeEndpoint.name;
    final skill = _skillStore.activeSkill;

    return Scaffold(
      appBar: AppBar(
        // 簡易模式選了 A～D 風格：上方標題列跟著換成風格的底色
        backgroundColor: _simpleMode && _simpleStyle != SimpleStyle.classic
            ? SimpleStyleSpec.of(_simpleStyle).bg
            : null,
        foregroundColor: _simpleMode && _simpleStyle != SimpleStyle.classic
            ? SimpleStyleSpec.of(_simpleStyle).text
            : null,
        title: Tooltip(
          message: _simpleMode ? '切換到聊天模式' : '切換到簡易模式',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _toggleSimpleMode,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                Icon(_simpleMode ? Icons.mic_rounded : Icons.blinds_rounded,
                    color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '隆美系統櫃助理',
                    // height: 1 讓文字的行高跟字一樣大，才會跟圖示垂直置中對齊
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, height: 1.0),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.swap_horiz_rounded,
                    size: 18, color: theme.colorScheme.outline),
              ]),
            ),
          ),
        ),
        titleSpacing: 12, // 跟左邊螢幕邊緣留一點間距
        centerTitle: false, // 標題靠左，功能靠右
        actions: [
          _ConnectionIndicator(
            status: status,
            epName: epName,
            onTap: () => Navigator.pushNamed(context, '/settings'),
          ),
          IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: '清除對話',
              onPressed: _showClearDialog),
          // 其他功能收進選單：語音狀態、語音設定、系統櫃配置、設定
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'voice':
                  _openVoiceSettings();
                case 'conversation':
                  unawaited(_openConversationSettings());
                case 'skill':
                  _showSkillPicker();
                case 'cabinet':
                  // 已選的櫃子一起帶進配置頁，之後兩邊保持同步
                  _openCabinetConfig();
                case 'settings':
                  Navigator.pushNamed(context, '/settings');
              }
            },
            itemBuilder: (ctx) => [
              // 語音狀態：只是顯示，不能按
              PopupMenuItem<String>(
                enabled: false,
                child: Row(children: [
                  Icon(
                    _voiceAvailable
                        ? Icons.mic_rounded
                        : Icons.mic_off_rounded,
                    size: 20,
                    color: _voiceAvailable
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 12),
                  Text(_voiceAvailable ? '麥克風可用' : '麥克風不可用'),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'voice',
                child: Row(children: [
                  Icon(
                      _ttsEnabled
                          ? Icons.volume_up_rounded
                          : Icons.volume_off_rounded,
                      size: 20),
                  const SizedBox(width: 12),
                  Text(_ttsEnabled ? '語音設定（回覆會唸出）' : '語音設定（回覆不唸）'),
                ]),
              ),
              PopupMenuItem<String>(
                value: 'conversation',
                child: Row(children: [
                  const Icon(Icons.record_voice_over_rounded, size: 20),
                  const SizedBox(width: 12),
                  Text(_voice.settings.continuous
                      ? '對話設定與風格（連續對話開）'
                      : '對話設定與風格'),
                ]),
              ),
              // 新版簡易畫面沒有最下面那一排了，切換助理放在這裡
              const PopupMenuItem<String>(
                value: 'skill',
                child: Row(children: [
                  Icon(Icons.swap_horiz_rounded, size: 20),
                  SizedBox(width: 12),
                  Text('切換助理'),
                ]),
              ),
              const PopupMenuItem<String>(
                value: 'cabinet',
                child: Row(children: [
                  Icon(Icons.view_in_ar_rounded, size: 20),
                  SizedBox(width: 12),
                  Text('系統櫃配置'),
                ]),
              ),
              const PopupMenuItem<String>(
                value: 'settings',
                child: Row(children: [
                  Icon(Icons.settings_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('設定'),
                ]),
              ),
            ],
          ),
        ],
        bottom: _simpleMode ? null : PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: GestureDetector(
            onTap: _showSkillPicker,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
              child: Row(children: [
                Text(skill.icon, style: const TextStyle(fontSize: 14)),
                Flexible(
                  child: Text(
                    skill.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    skill.isAllToolsAllowed
                        ? '· 全部工具'
                        : skill.isNoToolsMode
                            ? '· 不使用工具'
                            : '· ${skill.allowedTools.length} 個工具',
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.outline),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const Spacer(),
                Icon(Icons.expand_more_rounded,
                    size: 16, color: theme.colorScheme.outline),
              ]),
            ),
          ),
        ),
      ),
      body: PageView(
        controller: _pager,
        onPageChanged: _onPageChanged,
        children: [
          _SimpleVoiceView(
              voiceAvailable: _voiceAvailable,
              isRecording: _isRecording,
              isLoading: _isLoading,
              isSpeaking: _isSpeaking,
              heardText: _heardText,
              micLevel: _micLevel,
              replyText: _replyText.substring(
                  0, _replyShown.floor().clamp(0, _replyText.length)),
              skillIcon: skill.icon,
              skillName: skill.name,
              endpointName: epName,
              onMicTap: _onSimpleMicTap,
              onMicLongPress: () => unawaited(_openConversationSettings()),
              continuous: _voice.settings.continuous,
              style: _simpleStyle,
              onBackToChat: _toggleSimpleMode,
              onPickSkill: _showSkillPicker,
              onOpenSettings: () => Navigator.pushNamed(context, '/settings'),
              messages: _messages,
              progressText: _progress,
              pendingOrder: _showOrderButtons,
              onConfirmOrder: _confirmOrder,
              onEditOrder: _editOrder,
              // 最後一則 AI 回覆帶的連結（例如更新詢單），顯示成按鈕、按了才開
              actionLinks: _messages.isNotEmpty && !_messages.last.isUser
                  ? _messages.last.actionLinks
                  : const [],
              onReopenPicker:
                  _messages.isEmpty ? null : _reopenPickerFor(_messages.length - 1),
              picked: _picked,
              pickedExpanded: _pickedExpanded,
              onTogglePicked: () =>
                  setState(() => _pickedExpanded = !_pickedExpanded),
              onEditPicked: (p) => unawaited(_editPicked(p)),
              pickedPrice: _quoteView.price,
              pickedBusy: _quoteView.busy,
              pickedSent: _picked.isNotEmpty && !_pickedUnsent,
              onPick: () => _openPicker(),
              onSendPicked: () => _send(''),
            onEditMessage: (m) => unawaited(_chooseEditMode(m)),
            editingText:
                (_editing != null && _editByVoice) ? _editing!.text : null,
            onCancelEdit: _cancelEdit,
              onRemovePicked: (p) {
                setState(() => _picked.remove(p));
                _syncPickedToConfig();
              },
              onPickedQty: (p, q) {
                setState(() {
                  final i = _picked.indexOf(p);
                  if (i >= 0) _picked[i] = p.withQuantity(q);
                });
                _syncPickedToConfig();
              },
            ),
          Column(children: [
              Expanded(
                // 系統櫃視窗（挑選產品等）預設只貼在這一塊，輸入列和標籤仍然看得到
                child: DockRegion(
                  controller: GetIt.instance<CabinetWebController>(),
                  child: _messages.isEmpty
                    ? _EmptyHint()
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        itemCount: _messages.length + (_isLoading ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (i == _messages.length) {
                            return _TypingIndicator(label: _progress)
                                .animate()
                                .fadeIn(duration: 200.ms);
                          }
                          final orderButtons =
                              i == _messages.length - 1 && _showOrderButtons;
                          final m = _messages[i];
                          return _ChatBubble(
                                  msg: m,
                                  isEditing: identical(m, _editing),
                                  onEdit: _canEdit(m)
                                      ? () => _chooseEditMode(m)
                                      : null,
                                  onSwitch: _isLoading || _isRecording
                                      ? null
                                      : (d) => _switchBranch(m, d),
                                  onReopenPicker: _reopenPickerFor(i),
                                  onConfirmOrder:
                                      orderButtons ? _confirmOrder : null,
                                  onEditOrder: orderButtons ? _editOrder : null)
                              .animate()
                              .fadeIn(duration: 300.ms)
                              .slideY(begin: 0.08, duration: 300.ms);
                        },
                      ),
                ),
              ),
              _InputBar(
                controller: _ctrl,
                isLoading: _isLoading,
                isRecording: _isRecording,
                voiceAvailable: _voiceAvailable,
                onSend: _send,
                editing: _editing != null,
                editByVoice: _editing != null && _editByVoice,
                onCancelEdit: _cancelEdit,
                onQuickCommand: _showQuickCommands,
                picked: _picked,
                pickedExpanded: _pickedExpanded,
                onTogglePicked: () =>
                    setState(() => _pickedExpanded = !_pickedExpanded),
                onEditPicked: (p) => unawaited(_editPicked(p)),
                pickedPrice: _quoteView.price,
                pickedBusy: _quoteView.busy,
                pickedSent: _picked.isNotEmpty && !_pickedUnsent,
                onPick: () => _openPicker(),
                onRemovePicked: (p) {
                  setState(() => _picked.remove(p));
                  _syncPickedToConfig();
                },
                onPickedQty: (p, q) {
                  setState(() {
                    final i = _picked.indexOf(p);
                    if (i >= 0) _picked[i] = p.withQuantity(q.clamp(1, 99));
                  });
                  _syncPickedToConfig();
                },
                // 長按麥克風說話：文字即時出現在輸入框，放開後留著，看過、改過再按送出
                onPTTStart: () async {
                  HapticFeedback.mediumImpact();
                  _dictBase = _ctrl.text;
                  setState(() => _dictating = true);
                  await _voice.startDictation();
                },
                onPTTStop: () async {
                  HapticFeedback.lightImpact();
                  final text = await _voice.stopDictation();
                  if (!mounted) return;
                  setState(() => _dictating = false);
                  if (text != null) {
                    final c = GetIt.instance<CabinetWebController>();
                    if (c.acceptsVoice) {
                      // 視窗開著：先交給網頁操作畫面，網頁聽不懂就放進輸入框，確認後送給 AI
                      final r = await c.voiceCommand(text);
                      if (r['handled'] != true) _fillDictation(text);
                    } else {
                      _fillDictation(text);
                    }
                  }
                },
              ),
            ])
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pager.dispose();
    _revealTimer?.cancel();
    _voice.onSpeakingChanged = null;
    _voice.onSpeakText = null;
    _voice.onSpeakProgress = null;
    _voice.onMicLevel = null;
    _micLevel.dispose();
    _connectivity.removeListener(_onConnectivityChanged);
    _chat.progress.removeListener(_onProgress);
    GetIt.instance<CabinetWebController>().onCabinetsChanged = null;
    GetIt.instance<CabinetWebController>().onSendToChat = null;
    _testInputTimer?.cancel();
    _quote.onSynced = null;
    _quote.removeListener(_onQuoteChanged);
    _skillStore.removeListener(_onSkillChanged);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

// ════════════════════════════════════════════════════════
// 語音設定小視窗：語音回覆開關、語速、音調、聲音（可試聽）
// ════════════════════════════════════════════════════════
class _VoiceSettingsDialog extends StatefulWidget {
  final MobileVoiceOutput tts;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;

  const _VoiceSettingsDialog({
    required this.tts,
    required this.enabled,
    required this.onEnabledChanged,
  });

  @override
  State<_VoiceSettingsDialog> createState() => _VoiceSettingsDialogState();
}

class _VoiceSettingsDialogState extends State<_VoiceSettingsDialog> {
  static const _sample = '您好，我是隆美系統櫃助理，很高興為您服務。';

  late bool _enabled = widget.enabled;
  List<TtsVoice>? _voices;

  // 試聽中調整語速／音調 → 用新設定重唸（語音引擎沒辦法在一句話中途變速）
  bool _previewing = false;
  Timer? _replayTimer;

  void _play() {
    _previewing = true;
    _tts.preview(_sample);
  }

  void _replayIfPreviewing() {
    if (!_previewing || !_tts.isSpeaking) return;
    _replayTimer?.cancel();
    _replayTimer =
        Timer(const Duration(milliseconds: 250), () => _tts.preview(_sample));
  }

  @override
  void dispose() {
    _replayTimer?.cancel();
    super.dispose();
  }

  MobileVoiceOutput get _tts => widget.tts;

  @override
  void initState() {
    super.initState();
    _tts.listVoices().then((v) {
      if (mounted) setState(() => _voices = v);
    });
  }

  Future<void> _setRate(double v) async {
    await _tts.setRate(v);
    setState(() {});
    _replayIfPreviewing();
    _tts.saveSettings();
  }

  Future<void> _setPitch(double v) async {
    await _tts.setPitch(v);
    setState(() {});
    _replayIfPreviewing();
    _tts.saveSettings();
  }

  Future<void> _pickVoice(TtsVoice? v) async {
    HapticFeedback.selectionClick();
    await _tts.setVoice(v);
    setState(() {});
    _tts.saveSettings();
    _play(); // 選了就試聽
  }

  Future<void> _reset() async {
    await _tts.setRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.setVoice(null);
    setState(() {});
    _tts.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: 440, maxHeight: size.height * 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── 標題 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
            child: Row(children: [
              Icon(Icons.record_voice_over_outlined, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Text('語音設定',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                tooltip: '關閉',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),

          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 語音回覆開關 ──
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('語音回覆'),
                    subtitle: Text(_enabled ? 'AI 會唸出回答' : '關閉時只顯示文字'),
                    value: _enabled,
                    onChanged: (v) {
                      setState(() => _enabled = v);
                      widget.onEnabledChanged(v);
                    },
                  ),
                  const Divider(),

                  // ── 語速、音調 ──
                  _stepper(
                    label: '語速',
                    hint: '0.5 = 正常',
                    value: _tts.rate,
                    min: 0.1,
                    max: 1.0,
                    onChanged: _setRate,
                  ),
                  _stepper(
                    label: '音調',
                    hint: '1.0 = 正常',
                    value: _tts.pitch,
                    min: 0.5,
                    max: 2.0,
                    onChanged: _setPitch,
                  ),
                  const Divider(),

                  // ── 聲音 ──
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Row(children: [
                      Text('聲音',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Text('點一下選擇並試聽',
                          style: TextStyle(fontSize: 12, color: cs.outline)),
                    ]),
                  ),
                  ..._voiceTiles(context),
                ],
              ),
            ),
          ),

          // ── 底部按鈕 ──
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 16, 12),
            child: Row(children: [
              TextButton(onPressed: _reset, child: const Text('恢復預設')),
              const Spacer(),
              FilledButton.tonalIcon(
                // 淺色主題把 FilledButton 設成滿版寬，放在 Row 裡會出錯，這裡指定一般寬度
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('試聽'),
                onPressed: _play,
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// 標籤 + 數值，下面一條：[−] 滑桿 [+]，每格 0.1
  Widget _stepper({
    required String label,
    required String hint,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(label,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Text(hint, style: TextStyle(fontSize: 12, color: cs.outline)),
          const Spacer(),
          Text(value.toStringAsFixed(1),
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
        Row(children: [
          IconButton(
            tooltip: '減少',
            icon: const Icon(Icons.remove_rounded),
            onPressed: value > min + 0.001 ? () => onChanged(value - 0.1) : null,
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: ((max - min) * 10).round(),
              label: value.toStringAsFixed(1),
              onChanged: onChanged,
            ),
          ),
          IconButton(
            tooltip: '增加',
            icon: const Icon(Icons.add_rounded),
            onPressed: value < max - 0.001 ? () => onChanged(value + 0.1) : null,
          ),
        ]),
      ]),
    );
  }

  List<Widget> _voiceTiles(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final voices = _voices;
    if (voices == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: LinearProgressIndicator(),
        ),
      ];
    }
    if (voices.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('這台裝置找不到中文語音，請到系統設定安裝中文（台灣）語音',
              style: TextStyle(color: cs.outline)),
        ),
      ];
    }

    final choice = _tts.voiceChoice;
    Widget tile({
      required bool selected,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
    }) {
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tileColor: selected ? cs.primaryContainer.withValues(alpha: 0.5) : null,
        leading: Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: selected ? cs.primary : cs.outline),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(Icons.play_circle_outline_rounded, color: cs.primary),
        onTap: onTap,
      );
    }

    String tags(TtsVoice v) => [
          v.locale,
          if (v.isNatural) '自然',
          if (v.isOnline && !v.isNatural) '線上',
          if (v.isCantonese) '粵語',
        ].join(' · ');

    return [
      tile(
        selected: choice == null,
        title: '自動（推薦）',
        subtitle: choice == null && _tts.activeVoice != null
            ? '目前：${_tts.activeVoice!.name}'
            : '自動挑最自然的中文聲音',
        onTap: () => _pickVoice(null),
      ),
      for (final v in voices)
        tile(
          selected: choice?.name == v.name,
          title: v.name,
          subtitle: tags(v),
          onTap: () => _pickVoice(v),
        ),
    ];
  }
}

// ════════════════════════════════════════════════════════
// Skill 選擇器 Bottom Sheet
// ════════════════════════════════════════════════════════
class _SkillPickerSheet extends StatefulWidget {
  final SkillStore skillStore;
  final void Function(SkillModel) onSelected;
  final VoidCallback onManage;

  const _SkillPickerSheet({
    required this.skillStore,
    required this.onSelected,
    required this.onManage,
  });

  @override
  State<_SkillPickerSheet> createState() => _SkillPickerSheetState();
}

class _SkillPickerSheetState extends State<_SkillPickerSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.skillStore.activeSkill;

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(children: [
            // ── 拖曳把手 ──────────────────────────────
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),

            // ── 標題列（固定，不捲動）─────────────────
            Row(children: [
              Text('選擇助理模式',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.tune_rounded, size: 16),
                label: const Text('管理'),
                onPressed: widget.onManage,
              ),
            ]),
            const SizedBox(height: 8),

            // ── 可捲動的 Skill 清單 ───────────────────
            Expanded(
              child: ListView(
                controller: scrollController, // ✅ 現在在 StatefulWidget 內，正常運作
                children: widget.skillStore.skills.map((skill) {
                  final isActive = skill.id == active.id;
                  return ListTile(
                    leading:
                        Text(skill.icon, style: const TextStyle(fontSize: 24)),
                    title: Text(skill.name,
                        style: TextStyle(
                          fontWeight:
                              isActive ? FontWeight.bold : FontWeight.normal,
                          color: isActive ? theme.colorScheme.primary : null,
                        )),
                    subtitle: Text(
                      skill.description.isEmpty
                          ? (skill.isAllToolsAllowed
                              ? '全部工具'
                              : skill.isNoToolsMode
                                  ? '不使用工具'
                                  : '${skill.allowedTools.length} 個工具')
                          : skill.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.outline),
                    ),
                    trailing: isActive
                        ? Icon(Icons.check_circle_rounded,
                            color: theme.colorScheme.primary)
                        : null,
                    onTap: () => widget.onSelected(skill),
                  );
                }).toList(),
              ),
            ),
          ]),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════
// 連線狀態指示器
// ════════════════════════════════════════════════════════
class _ConnectionIndicator extends StatelessWidget {
  final ConnectionStatus status;
  final String epName;
  final VoidCallback onTap;

  const _ConnectionIndicator({
    required this.status,
    required this.epName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (status) {
      ConnectionStatus.connected => (Colors.green, Icons.wifi_rounded, '已連線'),
      ConnectionStatus.disconnected => (
          Colors.red,
          Icons.wifi_off_rounded,
          '未連線'
        ),
      ConnectionStatus.checking => (
          Colors.orange,
          Icons.wifi_find_rounded,
          '檢查中'
        ),
      ConnectionStatus.unknown => (Colors.grey, Icons.wifi_lock_rounded, '未知'),
    };

    return Tooltip(
      message: '$epName・$label',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(color: color.withOpacity(0.6), blurRadius: 6),
                ],
              ),
            )
                .animate(
                  onPlay: (c) => status == ConnectionStatus.checking
                      ? c.repeat(reverse: true)
                      : c.forward(from: 1.0),
                )
                .fadeIn(duration: 500.ms),
            const SizedBox(width: 5),
            // 連線名稱太長時截斷，才不會把靠左的標題擠掉
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 72),
              child: Text(
                epName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// 空白提示
// ════════════════════════════════════════════════════════
class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.chat_bubble_outline_rounded,
            size: 64, color: theme.colorScheme.outlineVariant),
        const SizedBox(height: 16),
        Text('開始您的對話',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.outline)),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════
// 聊天泡泡（Layer 6：資料來源標籤）
// ════════════════════════════════════════════════════════
/// AI 訊息內容（Markdown）。
/// 表格在窄螢幕放不下時，先只顯示重點欄位（案號、客戶、金額、日期），
/// 下方有「顯示全部欄位」可以切換成完整表格（可左右滑動）。
class _MessageMarkdown extends StatefulWidget {
  final String text;
  const _MessageMarkdown({required this.text});

  @override
  State<_MessageMarkdown> createState() => _MessageMarkdownState();
}

class _MessageMarkdownState extends State<_MessageMarkdown> {
  bool _showAll = false;

  static const _keyWords = ['案號', '案場編號', '編號', '客戶', '金額', '日期'];

  static List<String> _cells(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|').map((c) => c.trim()).toList();
  }

  static bool _isTableLine(String line) {
    final t = line.trim();
    return t.startsWith('|') && t.endsWith('|') && t.length > 2;
  }

  /// 表格欄數（看第一個表格）
  static int _tableColumns(String md) {
    for (final line in md.split('\n')) {
      if (_isTableLine(line)) return _cells(line).length;
    }
    return 0;
  }

  /// 表格需要的寬度：每欄取最長的內容估算（中文約 16px、英數約 9px，加左右留白）
  static double _tableWidth(String md) {
    final widths = <int, double>{};
    for (final line in md.split('\n')) {
      if (!_isTableLine(line)) continue;
      final cells = _cells(line);
      if (cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) continue; // 分隔列
      for (var i = 0; i < cells.length; i++) {
        final w = cells[i].replaceAll('**', '').runes
                .fold<double>(0, (sum, r) => sum + (r > 255 ? 16 : 9)) +
            24;
        if (w > (widths[i] ?? 0)) widths[i] = w;
      }
    }
    return widths.values.fold<double>(0, (a, b) => a + b) + 8;
  }

  /// 每個表格只留重點欄位；找不到重點欄位就留前 3 欄
  static String _compact(String md) {
    final lines = md.split('\n');
    final out = <String>[];
    var i = 0;
    while (i < lines.length) {
      if (!_isTableLine(lines[i])) {
        out.add(lines[i]);
        i++;
        continue;
      }
      final block = <String>[];
      while (i < lines.length && _isTableLine(lines[i])) {
        block.add(lines[i]);
        i++;
      }
      final header = _cells(block.first);
      var keep = <int>[];
      for (var c = 0; c < header.length && keep.length < 4; c++) {
        if (_keyWords.any(header[c].contains)) keep.add(c);
      }
      if (keep.length < 2) {
        keep = List.generate(header.length < 3 ? header.length : 3, (c) => c);
      }
      for (final row in block) {
        final cells = _cells(row);
        out.add('| ${keep.map((c) => c < cells.length ? cells[c] : '').join(' | ')} |');
      }
    }
    return out.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, box) {
      Widget markdown(String data) => MarkdownBody(
            data: data,
            // 單一換行也換行（模型常用一行一筆列資料）
            softLineBreak: true,
            // 讓訊息裡的連結可以點
            onTapLink: (text, href, title) {
              if (href != null) openLink(href);
            },
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
              listBullet: theme.textTheme.bodyLarge,
              tableColumnWidth: const IntrinsicColumnWidth(),
              tableCellsPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
          );

      final cols = _tableColumns(widget.text);
      final need = _tableWidth(widget.text);
      final tooWide =
          cols > 0 && box.maxWidth.isFinite && need > box.maxWidth;
      if (!tooWide) return markdown(widget.text);

      final compact     = _compact(widget.text);
      final compactNeed = _tableWidth(compact);
      Widget scrollable(Widget child, double width) => width <= box.maxWidth
          ? child
          : Scrollbar(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: width, child: child),
              ),
            );

      final toggle = Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 8)),
          onPressed: () => setState(() => _showAll = !_showAll),
          icon: Icon(
              _showAll ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
              size: 18),
          label: Text(_showAll ? '只看重點欄位' : '顯示全部欄位（$cols 欄）'),
        ),
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _showAll
              // 完整表格：可左右滑動
              ? scrollable(markdown(widget.text), need)
              // 重點欄位：通常放得下，放不下一樣可以左右滑動
              : scrollable(markdown(compact), compactNeed),
          toggle,
        ],
      );
    });
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage msg;
  final VoidCallback? onConfirmOrder, onEditOrder; // 待確認的新訂單才有
  final VoidCallback? onReopenPicker; // 最後一則是「請挑選櫃子」才有：重新開啟挑選畫面
  final VoidCallback? onEdit; // 長按自己的訊息 → 編輯（開新分支）
  final void Function(int delta)? onSwitch; // ‹ › 切換版本；null = 暫時不能切
  final bool isEditing;
  const _ChatBubble({
    required this.msg,
    this.onConfirmOrder,
    this.onEditOrder,
    this.onReopenPicker,
    this.onEdit,
    this.onSwitch,
    this.isEditing = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = msg.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // ── 訊息泡泡（自己的訊息長按可編輯）──────────────
          GestureDetector(
            onLongPress: isUser ? onEdit : null,
            child: Container(
              margin: EdgeInsets.only(
                top: 4,
                bottom: 2,
                left: isUser ? 48 : 0,
                right: isUser ? 0 : 48,
              ),
              decoration: BoxDecoration(
                color: isUser
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(isUser ? 20 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 20),
                ),
                border: isEditing
                    ? Border.all(color: theme.colorScheme.tertiary, width: 2.5)
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.07),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: isUser
                    ? Text(msg.text,
                        style: TextStyle(
                            color: theme.colorScheme.onPrimary,
                            fontSize: 16,
                            height: 1.5))
                    : _MessageMarkdown(text: msg.text),
              ),
            ),
          ),

          // ── 版本切換：‹ 2/3 ›（這則被編輯過才有）──────────
          if (isUser && msg.branch != null && msg.branch!.versions.length > 1)
            Builder(builder: (context) {
              final g = msg.branch!;
              final canPrev = onSwitch != null && g.active > 0;
              final canNext =
                  onSwitch != null && g.active < g.versions.length - 1;
              return Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded),
                  iconSize: 20,
                  tooltip: '上一個版本',
                  visualDensity: VisualDensity.compact,
                  onPressed: canPrev ? () => onSwitch!(-1) : null,
                ),
                Text('${g.active + 1}/${g.versions.length}',
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.outline)),
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded),
                  iconSize: 20,
                  tooltip: '下一個版本',
                  visualDensity: VisualDensity.compact,
                  onPressed: canNext ? () => onSwitch!(1) : null,
                ),
              ]);
            }),

          // ── 請挑選櫃子：挑選畫面被關掉時，從這裡重新打開 ──
          if (!isUser && onReopenPicker != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: FilledButton.tonalIcon(
                onPressed: onReopenPicker,
                icon: const Icon(Icons.view_list_rounded, size: 18),
                label: const Text('重新開啟挑選畫面'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  textStyle: const TextStyle(fontSize: 15),
                ),
              ),
            ),

          // ── 新訂單摘要：確認建立／修改（正式建立只能按這裡）──
          if (onConfirmOrder != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Wrap(spacing: 8, runSpacing: 6, children: [
                FilledButton.icon(
                  onPressed: onConfirmOrder,
                  icon: const Icon(Icons.check_circle_rounded, size: 18),
                  label: const Text('確認建立'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onEditOrder,
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('修改'),
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                ),
              ]),
            ),

          // ── 工具給的待辦連結（例如詢單頁）：自動開啟被擋時可以手動點 ──
          if (!isUser && msg.actionLinks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: msg.actionLinks
                    .map((l) => FilledButton.tonalIcon(
                          onPressed: () => openLink(l.url),
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: Text('開啟：${l.label}'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            textStyle: const TextStyle(fontSize: 14),
                          ),
                        ))
                    .toList(),
              ),
            ),

          // ── ✅ Layer 6：資料來源標籤 ──────────────────
          if (!isUser)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  msg.toolsUsed.isEmpty
                      // 純 AI 推理（無工具）
                      ? Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.psychology_outlined,
                              size: 11,
                              color:
                                  theme.colorScheme.outline.withOpacity(0.5)),
                          const SizedBox(width: 3),
                          Text(
                            'AI 推理',
                            style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.outline.withOpacity(0.5),
                            ),
                          ),
                        ])
                      // 有工具資料 → 顯示工具名稱標籤
                      : Wrap(
                          spacing: 4,
                          children: msg.toolsUsed.map((tool) {
                            final label = GetIt.instance<ChatOrchestrator>()
                                .toolDisplayName(tool);
                            return Tooltip(
                              message: tool, // 滑過顯示原本的工具名稱，方便開發除錯
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.green.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: Colors.green.shade200, width: 0.8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.verified_outlined,
                                        size: 10, color: Colors.green.shade700),
                                    const SizedBox(width: 3),
                                    Text(
                                      label,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.green.shade700,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                  if (msg.trace != null) _TraceButton(trace: msg.trace!),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// 推理過程：按鈕 + 時間軸面板
// ════════════════════════════════════════════════════════
class _TraceButton extends StatelessWidget {
  final ReasoningTrace trace;
  const _TraceButton({required this.trace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        trace.hasProblem ? Colors.orange.shade700 : theme.colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _TraceSheet(trace: trace),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            trace.hasProblem
                ? Icons.report_problem_outlined
                : Icons.account_tree_outlined,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 3),
          Text('推理過程',
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

class _TraceSheet extends StatelessWidget {
  final ReasoningTrace trace;
  const _TraceSheet({required this.trace});

  static ({IconData icon, Color color, String label}) _style(
      TraceKind k, ColorScheme cs) {
    return switch (k) {
      TraceKind.input => (
          icon: Icons.person_outline_rounded,
          color: cs.primary,
          label: '輸入'
        ),
      TraceKind.mcp => (
          icon: Icons.hub_outlined,
          color: Colors.teal,
          label: 'MCP'
        ),
      TraceKind.llmRequest => (
          icon: Icons.upload_rounded,
          color: Colors.indigo,
          label: '詢問模型'
        ),
      TraceKind.llmResponse => (
          icon: Icons.smart_toy_outlined,
          color: Colors.indigo,
          label: '模型回應'
        ),
      TraceKind.thinking => (
          icon: Icons.psychology_outlined,
          color: Colors.purple,
          label: '思考'
        ),
      TraceKind.toolCall => (
          icon: Icons.build_outlined,
          color: Colors.blue,
          label: '呼叫工具'
        ),
      TraceKind.toolResult => (
          icon: Icons.inventory_2_outlined,
          color: Colors.green,
          label: '工具結果'
        ),
      TraceKind.blocked => (
          icon: Icons.block_rounded,
          color: Colors.red,
          label: '攔截'
        ),
      TraceKind.warning => (
          icon: Icons.warning_amber_rounded,
          color: Colors.orange,
          label: '注意'
        ),
      TraceKind.error => (
          icon: Icons.error_outline_rounded,
          color: Colors.red,
          label: '錯誤'
        ),
      TraceKind.answer => (
          icon: Icons.check_circle_outline_rounded,
          color: Colors.green,
          label: '回覆'
        ),
    };
  }

  static String _secs(Duration d) =>
      '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(children: [
        // ── 摘要 ──────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('推理過程',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                _chip(
                    context, Icons.timer_outlined, '耗時 ${_secs(trace.total)}'),
                _chip(context, Icons.loop_rounded, '詢問模型 ${trace.rounds} 次'),
                _chip(
                    context,
                    Icons.build_outlined,
                    trace.toolsCalled.isEmpty
                        ? '沒有呼叫工具'
                        : '呼叫工具 ${trace.toolsCalled.length} 次'),
                if (trace.hasProblem)
                  _chip(context, Icons.report_problem_outlined, '有攔截或警告',
                      color: Colors.orange.shade700),
              ]),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── 時間軸 ────────────────────────────────────
        Expanded(
          child: ListView.builder(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: trace.steps.length,
            itemBuilder: (context, i) {
              final step = trace.steps[i];
              final style = _style(step.kind, cs);
              final isLast = i == trace.steps.length - 1;
              // 用 Stack 畫時間軸線（避免 IntrinsicHeight 量測 SelectableText 造成卡頓）
              return Stack(children: [
                if (!isLast)
                  Positioned(
                    left: 17,
                    top: 28,
                    bottom: 0,
                    child: Container(width: 2, color: cs.outlineVariant),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 36,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: style.color.withValues(alpha: 0.15),
                          child: Icon(style.icon, size: 16, color: style.color),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _StepBody(
                            step: step,
                            style: style,
                            secs: _secs(step.elapsed)),
                      ),
                    ),
                  ],
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String text,
      {Color? color}) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: c)),
      ]),
    );
  }
}

/// 單一步驟：標題一行，有細節時可點開
class _StepBody extends StatefulWidget {
  final TraceStep step;
  final ({IconData icon, Color color, String label}) style;
  final String secs;
  const _StepBody(
      {required this.step, required this.style, required this.secs});

  @override
  State<_StepBody> createState() => _StepBodyState();
}

class _StepBodyState extends State<_StepBody> {
  late bool _open;

  @override
  void initState() {
    super.initState();
    // 問題類與最終回覆預設展開，其餘收合
    _open = switch (widget.step.kind) {
      TraceKind.blocked ||
      TraceKind.warning ||
      TraceKind.error ||
      TraceKind.answer ||
      TraceKind.input =>
        true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final detail = widget.step.detail;
    final hasDetail = detail != null && detail.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: hasDetail ? () => setState(() => _open = !_open) : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: widget.style.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(widget.style.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: widget.style.color,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.step.title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
              ),
              Text(widget.secs,
                  style:
                      theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
              if (hasDetail)
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: cs.outline),
            ]),
          ),
        ),
        if (hasDetail && _open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              detail,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace', height: 1.5),
            ),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════
// 打字中動畫指示器
// ════════════════════════════════════════════════════════
class _TypingIndicator extends StatelessWidget {
  final String? label; // 目前在做什麼，例如「查詢龍美系統櫃訂單中…」
  const _TypingIndicator({this.label});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomRight: Radius.circular(20),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
           ...List.generate(
            3,
            (i) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                  color: theme.colorScheme.primary, shape: BoxShape.circle),
            )
                .animate(onPlay: (c) => c.repeat())
                .moveY(
                    begin: 0,
                    end: -7,
                    delay: (i * 160).ms,
                    duration: 400.ms,
                    curve: Curves.easeInOut)
                .then()
                .moveY(
                    begin: -7,
                    end: 0,
                    duration: 400.ms,
                    curve: Curves.easeInOut),
          ),
            if (label != null) ...[
              const SizedBox(width: 10),
              Flexible(
                child: Text(label!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// 快速指令 Bottom Sheet
// ════════════════════════════════════════════════════════
class _QuickCommandSheet extends StatelessWidget {
  final void Function(String) onSelected;
  const _QuickCommandSheet({required this.onSelected});

  static const _commands = [
    ('📦 查詢訂單', '查詢最近的訂單狀態'),
    ('📋 訂單明細', '查詢訂單明細'),
    ('🚚 交貨日期', '確認交貨日期'),
    ('💰 訂單金額', '查詢訂單金額'),
    ('👤 客戶資料', '查詢客戶資料'),
    ('📊 庫存查詢', '查詢目前庫存'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: theme.colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 16),
        Text('快速指令',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _commands.map((cmd) {
            return ActionChip(
              label: Text(cmd.$1),
              onPressed: () => onSelected(cmd.$2),
              backgroundColor: theme.colorScheme.secondaryContainer,
              labelStyle:
                  TextStyle(color: theme.colorScheme.onSecondaryContainer),
            );
          }).toList(),
        ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════
// 已選的櫃子（輸入列上方）
// ════════════════════════════════════════════════════════
class _PickedTile extends StatelessWidget {
  final PickedItem item;
  final bool enabled;
  final VoidCallback onRemove;
  final VoidCallback? onEdit; // 點整張卡片：開網頁填寬度、開門方向等規格
  final void Function(int) onQty;

  const _PickedTile({
    required this.item,
    required this.enabled,
    required this.onRemove,
    required this.onQty,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onEdit : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: _body(cs),
          ),
        ),
      ),
    );
  }

  Widget _body(ColorScheme cs) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text('${item.productNo} ${item.name}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
              ),
              // 提示：點這張卡片可以編輯規格
              if (onEdit != null) ...[
                const SizedBox(width: 6),
                Icon(Icons.edit_outlined, size: 14, color: cs.primary),
              ],
            ]),
            if (item.wall != null && wallTagOf(item.wall).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('放在${wallTagOf(item.wall)}',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.primary)),
              ),
            if (item.specText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(item.specText,
                    style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
              ),
            if (item.missing.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                // 沒預設值的規格不算錯誤：背景試算完會自動帶入網站實際的預設值
                child: Text('未選：${item.missing.join('、')}（試算後自動帶入系統預設）',
                    style: TextStyle(fontSize: 12, color: cs.outline)),
              ),
          ]),
        ),
        // 數量 − n ＋
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          onPressed: enabled && item.quantity > 1 ? () => onQty(item.quantity - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('${item.quantity}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          onPressed: enabled ? () => onQty(item.quantity + 1) : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          onPressed: enabled ? onRemove : null,
          icon: const Icon(Icons.close_rounded),
        ),
    ]);
  }
}

/// 已選的櫃子：標題列（件數＋展開／縮起箭頭）＋卡片清單。
/// 清單有最大高度（超過在裡面捲動），才不會把上面的對話擠沒；縮起時只剩標題列和品號摘要。
/// 聊天模式與簡易模式共用。
class _PickedPanel extends StatelessWidget {
  final List<PickedItem> picked;
  final bool expanded, enabled;
  final VoidCallback? onToggle;
  final void Function(PickedItem) onRemove;
  final void Function(PickedItem, int) onQty;
  final void Function(PickedItem)? onEdit; // 點卡片 → 開網頁編輯規格
  final num? price; // 網站算出的總價（資料齊全才有，沒有就不顯示金額）
  final bool busy; // 正在跟網站核對預設值、算價
  final bool sent; // 這份清單已經送給 AI（之後有變動才會再送）

  const _PickedPanel({
    required this.picked,
    required this.expanded,
    required this.enabled,
    required this.onToggle,
    required this.onRemove,
    required this.onQty,
    this.onEdit,
    this.price,
    this.busy = false,
    this.sent = false,
  });

  static String _money(num v) {
    final s = v.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);
    // 最多佔可用高度（扣掉鍵盤）的 1/4，介於 96 ~ 240
    final maxH =
        ((mq.size.height - mq.viewInsets.bottom) * 0.25).clamp(96.0, 240.0);
    final total = picked.fold<int>(0, (s, p) => s + p.quantity);
    final summary = picked.map((p) => p.productNo).join('、');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // ── 標題列：整條都能點，高度 ≥ 44 ──
        Material(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onToggle,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
              child: Row(children: [
                Icon(Icons.inventory_2_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: '已選 ${picked.length} 種・共 $total 件',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      // 金額：跟網站核對、資料齊全才顯示；算的時候顯示試算中
                      if (busy)
                        TextSpan(
                          text: '　試算中…',
                          style: TextStyle(fontSize: 12.5, color: cs.outline),
                        )
                      else if (price != null)
                        TextSpan(
                          text: '　NT\$ ${_money(price!)}',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: cs.primary),
                        ),
                      if (sent)
                        TextSpan(
                          text: '　✓ 已送出',
                          style: TextStyle(fontSize: 12.5, color: cs.outline),
                        ),
                      // 縮起時顯示品號，才知道還有東西沒送出
                      if (!expanded)
                        TextSpan(
                          text: '　$summary',
                          style:
                              TextStyle(fontSize: 12.5, color: cs.outline),
                        ),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 縮起＝Λ（往上展開），展開＝轉成 V（往下收）
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_less_rounded,
                      size: 26, color: cs.onSurfaceVariant),
                ),
              ]),
            ),
          ),
        ),
        // ── 卡片清單：有最大高度，超過就捲動 ──
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: expanded
              ? ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(children: [
                      for (final p in picked)
                        _PickedTile(
                          item: p,
                          enabled: enabled,
                          onRemove: () => onRemove(p),
                          onQty: (q) => onQty(p, q),
                          onEdit: onEdit == null ? null : () => onEdit!(p),
                        ),
                    ]),
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════
// 輸入列
// ════════════════════════════════════════════════════════
class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading, isRecording, voiceAvailable;
  final void Function(String) onSend;
  final bool editing; // 正在編輯舊訊息（送出會開新分支）
  final bool editByVoice; // 編輯方式是語音重說
  final VoidCallback onCancelEdit;
  final VoidCallback onPTTStart, onPTTStop, onQuickCommand;
  final List<PickedItem> picked;
  final bool pickedExpanded; // 已選櫃子清單是否展開
  final VoidCallback onTogglePicked;
  final void Function(PickedItem) onEditPicked; // 點已選的櫃子 → 開網頁編輯規格
  final num? pickedPrice; // 已選櫃子的總價（網站算的，資料齊全才有）
  final bool pickedBusy; // 正在試算
  final bool pickedSent; // 已選清單已經送給 AI、沒有新的變動
  final VoidCallback onPick;
  final void Function(PickedItem) onRemovePicked;
  final void Function(PickedItem, int) onPickedQty;

  const _InputBar({
    required this.controller,
    required this.isLoading,
    required this.isRecording,
    required this.voiceAvailable,
    required this.onSend,
    required this.editing,
    required this.editByVoice,
    required this.onCancelEdit,
    required this.onPTTStart,
    required this.onPTTStop,
    required this.onQuickCommand,
    required this.picked,
    required this.pickedExpanded,
    required this.onTogglePicked,
    required this.onEditPicked,
    this.pickedPrice,
    this.pickedBusy = false,
    this.pickedSent = false,
    required this.onPick,
    required this.onRemovePicked,
    required this.onPickedQty,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 10,
            offset: const Offset(0, -3),
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 編輯舊訊息中：提醒送出會開新分支，舊的對話還在
          if (editing)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.only(left: 12, right: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Icon(Icons.edit_rounded,
                    size: 16, color: theme.colorScheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    editByVoice
                        ? '語音重說：長按麥克風重新說，放開後按送出會開新分支'
                        : '編輯訊息：送出後開新分支，原本的對話可以用 ‹ › 切回來',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onTertiaryContainer),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: '取消編輯',
                  visualDensity: VisualDensity.compact,
                  color: theme.colorScheme.onTertiaryContainer,
                  onPressed: onCancelEdit,
                ),
              ]),
            ),
          if (!voiceAvailable)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Icon(Icons.info_outline_rounded,
                    size: 14, color: theme.colorScheme.outline),
                const SizedBox(width: 4),
                Text(
                  '語音功能不可用，請使用文字或快速指令輸入',
                  style:
                      TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                ),
              ]),
            ),
          // 從目錄挑選的櫃子：每個一張小卡片，完整顯示規格，可調數量、可刪除
          if (picked.isNotEmpty)
            _PickedPanel(
              picked: picked,
              expanded: pickedExpanded,
              enabled: !isLoading,
              onToggle: onTogglePicked,
              onRemove: onRemovePicked,
              onQty: onPickedQty,
              onEdit: onEditPicked,
              price: pickedPrice,
              busy: pickedBusy,
              sent: pickedSent,
            ),
          // 沒有說出品號時，可以自己從目錄挑
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: (isLoading || isRecording) ? null : onPick,
              icon: const Icon(Icons.view_list_rounded, size: 18),
              label: const Text('從目錄挑選'),
            ),
          ),
          Row(children: [
            if (voiceAvailable) ...[
              AvatarGlow(
                animate: isRecording,
                glowColor: theme.colorScheme.error,
                glowRadiusFactor: 0.35,
                child: GestureDetector(
                  onLongPressStart: (_) => onPTTStart(),
                  onLongPressEnd: (_) => onPTTStop(),
                  child: CircleAvatar(
                    radius: 26,
                    backgroundColor: isRecording
                        ? theme.colorScheme.error
                        : theme.colorScheme.primaryContainer,
                    child: Icon(
                      isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                      color: isRecording
                          ? theme.colorScheme.onError
                          : theme.colorScheme.onPrimaryContainer,
                      size: 24,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (!voiceAvailable) ...[
              CircleAvatar(
                radius: 26,
                backgroundColor: theme.colorScheme.secondaryContainer,
                child: IconButton(
                  icon: Icon(Icons.grid_view_rounded,
                      color: theme.colorScheme.onSecondaryContainer, size: 22),
                  tooltip: '快速指令',
                  onPressed: onQuickCommand,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !isLoading && !isRecording,
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: onSend,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: isRecording
                      ? '🎤 說話中，放開後文字會留在這裡...'
                      : editByVoice
                          ? '長按麥克風，重新說一次...'
                          : voiceAvailable
                          ? '輸入訊息，或長按麥克風說話'
                          : '請輸入訊息...',
                  hintStyle:
                      TextStyle(color: theme.colorScheme.outline, fontSize: 14),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 26,
              backgroundColor: (isLoading || isRecording)
                  ? theme.colorScheme.surfaceContainerHighest
                  : theme.colorScheme.primary,
              child: isLoading
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: theme.colorScheme.primary))
                  : IconButton(
                      icon: Icon(Icons.send_rounded,
                          color: isRecording
                              ? theme.colorScheme.outline
                              : theme.colorScheme.onPrimary),
                      onPressed:
                          isRecording ? null : () => onSend(controller.text),
                    ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// 簡易模式：視訊對話版型（AI 格 + 你的格 + 文字對話）
// ════════════════════════════════════════════════════════
/// 寬螢幕（≥ 840）：左 4 兩格上下排（AI 上、你下），右 6 文字對話。
/// 手機：兩格左右並排在上方（高度依螢幕縮放），下方整塊是文字對話。
/// 正在講話的那格外框發光，另一格變暗；點「你」說話，回答中點「AI」可以打斷。
class _SimpleVoiceView extends StatefulWidget {
  final bool voiceAvailable, isRecording, isLoading, isSpeaking;
  final String heardText; // 聽到的話（說話時即時更新）
  final String replyText; // AI 回答字幕（目前唸到的部分）
  final ValueListenable<double> micLevel; // 說話音量 0 ~ 1
  final List<ChatMessage> messages;
  final String skillIcon, skillName, endpointName;
  final VoidCallback onMicTap, onBackToChat, onPickSkill, onOpenSettings;
  final VoidCallback? onMicLongPress; // 長按「你」：連續對話與插話設定
  final bool continuous; // 連續對話開著（「你」的標籤會標示）
  final SimpleStyle style; // 畫面風格：傳統＝原本的版面；其他＝底部大麥克風版面＋整套配色
  final String? progressText; // 思考／查詢時 AI 格的字幕
  final bool pendingOrder; // 有新訂單等確認 → 顯示確認列
  final VoidCallback onConfirmOrder, onEditOrder;
  final List<({String label, String url})> actionLinks; // 最後一則回覆的連結，顯示成按鈕
  final VoidCallback? onReopenPicker; // 最後一則是「請挑選櫃子」才有：重新開啟挑選畫面
  final List<PickedItem> picked; // 從目錄挑選的櫃子（跟聊天模式同一份）
  final bool pickedExpanded; // 已選櫃子清單是否展開（跟聊天模式同一個狀態）
  final VoidCallback? onTogglePicked;
  final void Function(PickedItem)? onEditPicked; // 點已選的櫃子 → 開網頁編輯規格
  final num? pickedPrice; // 已選櫃子的總價（網站算的，資料齊全才有）
  final bool pickedBusy; // 正在試算
  final bool pickedSent; // 已選清單已經送給 AI、沒有新的變動（不用再顯示「送出」）
  final VoidCallback onPick, onSendPicked;
  final void Function(PickedItem) onRemovePicked;
  final void Function(PickedItem, int) onPickedQty;
  final void Function(ChatMessage)? onEditMessage; // 長按自己說過的話 → 修改文字／語音重說
  final String? editingText; // 正在語音重說的那一句（null = 沒有在重說）
  final VoidCallback? onCancelEdit;

  const _SimpleVoiceView({
    this.onMicLongPress,
    this.continuous = false,
    this.style = SimpleStyle.classic,
    this.onEditMessage,
    this.editingText,
    this.onCancelEdit,
    required this.voiceAvailable,
    required this.isRecording,
    required this.isLoading,
    required this.isSpeaking,
    required this.heardText,
    required this.replyText,
    required this.micLevel,
    required this.messages,
    required this.skillIcon,
    required this.skillName,
    required this.endpointName,
    required this.onMicTap,
    required this.onBackToChat,
    required this.onPickSkill,
    required this.onOpenSettings,
    required this.progressText,
    required this.pendingOrder,
    required this.onConfirmOrder,
    required this.onEditOrder,
    this.actionLinks = const [],
    this.onReopenPicker,
    required this.picked,
    this.pickedExpanded = true,
    this.onTogglePicked,
    this.onEditPicked,
    this.pickedPrice,
    this.pickedBusy = false,
    this.pickedSent = false,
    required this.onPick,
    required this.onSendPicked,
    required this.onRemovePicked,
    required this.onPickedQty,
  });

  @override
  State<_SimpleVoiceView> createState() => _SimpleVoiceViewState();
}

enum _SimpleState { idle, listening, thinking, speaking }

class _SimpleVoiceViewState extends State<_SimpleVoiceView>
    with SingleTickerProviderStateMixin {
  static const _wideBreakpoint = 840.0;

  // 傳統版面的呼吸動畫。一開始就建好：新版面用不到它，如果等到第一次用才建，
  // 換成新版面後會在 dispose 時才第一次建立而出錯
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  _SimpleState get _state => widget.isRecording
      ? _SimpleState.listening
      : widget.isLoading
          ? _SimpleState.thinking
          : widget.isSpeaking
              ? _SimpleState.speaking
              : _SimpleState.idle;

  /// 選好的櫃子 + 「從目錄挑選」，跟聊天模式輸入列上的是同一份。
  /// 簡易模式不需要「送出」：每次說話都會自動把目前已選的櫃子與規格一起交給 AI。
  Widget _pickedBar(BuildContext context, {bool catalogRow = true}) {
    final busy = widget.isLoading || widget.isRecording;
    final styled = widget.style != SimpleStyle.classic;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.editingText != null)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              color: cs.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(Icons.mic_rounded, size: 18, color: cs.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    styled
                        ? '重說：「${widget.editingText}」，按下面的麥克風開始說'
                        : '重說：「${widget.editingText}」，點「你」開始說',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSecondaryContainer)),
              ),
              TextButton(
                onPressed: busy ? null : widget.onCancelEdit,
                child: const Text('取消'),
              ),
            ]),
          ),
        if (widget.picked.isNotEmpty)
          _PickedPanel(
            picked: widget.picked,
            expanded: widget.pickedExpanded,
            enabled: !widget.isLoading,
            onToggle: widget.onTogglePicked,
            onRemove: widget.onRemovePicked,
            onQty: widget.onPickedQty,
            onEdit: widget.onEditPicked,
            price: widget.pickedPrice,
            busy: widget.pickedBusy,
          ),
        // 新版面的「目錄」在底部按鈕列，這一排只有傳統版面需要
        if (catalogRow)
          Row(children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: busy ? null : widget.onPick,
              icon: const Icon(Icons.view_list_rounded, size: 18),
              label: const Text('從目錄挑選'),
            ),
            const Spacer(),
          ]),
      ]),
    );
  }

  /// 新版面（A～D 風格）：上面兩張狀態卡、中間文字對話、底部「目錄／麥克風／打字」。
  /// 整個畫面套用風格的配色（文字對話、已選清單、訂單按鈕也一起換），傳統版面不走這裡。
  Widget _buildStyled(BuildContext outer) {
    final spec = SimpleStyleSpec.of(widget.style);
    final state = _state;
    final phase = switch (state) {
      _SimpleState.idle => MicPhase.idle,
      _SimpleState.listening => MicPhase.listening,
      _SimpleState.thinking => MicPhase.thinking,
      _SimpleState.speaking => MicPhase.speaking,
    };
    // 卡片只顯示純文字：拿掉 Markdown 符號（**粗體**、# 標題、- 清單）
    String plain(String s) => s
        .replaceAll(RegExp(r'\*\*|__|`'), '')
        .replaceAll(RegExp(r'^\s*(#+|[-*•])\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\s*\n+\s*'), ' ')
        .trim();
    return Theme(
      data: spec.apply(Theme.of(outer)),
      // Material：讓沒指定顏色的文字也用這個風格的字色（App 是淺色模式時才不會深字疊深底）
      child: Material(
        type: MaterialType.transparency,
        child: Builder(builder: (context) {
        final reply = plain(widget.replyText);
        final lastAi = widget.messages.isNotEmpty && !widget.messages.last.isUser
            ? plain(widget.messages.last.text)
            : '';
        final aiText = state == _SimpleState.thinking
            ? (widget.progressText ?? '正在查詢資料…')
            : reply.isNotEmpty
                ? reply
                : lastAi.isNotEmpty
                    ? lastAi
                    : '有問題直接按下面的麥克風問我';
        final heard = widget.heardText.trim();
        final userText = heard.isNotEmpty
            ? heard
            : state == _SimpleState.listening
                ? '請說話…'
                : (widget.continuous ? '連續對話：按麥克風開始' : '按下面的麥克風說話');
        return SimpleBackdrop(
          spec: spec,
          child: SafeArea(
            top: false,
            child: LayoutBuilder(builder: (context, box) {
              final wide = box.maxWidth >= _wideBreakpoint;
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: SimpleStatusCards(
                    spec: spec,
                    phase: phase,
                    aiText: aiText,
                    userText: userText,
                    // AI 回答時點 AI 卡也能打斷
                    onAiTap: state == _SimpleState.speaking ? widget.onMicTap : null,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: DockRegion(
                      controller: GetIt.instance<CabinetWebController>(),
                      child: _transcriptPanel(context, state,
                          compact: !wide, radius: spec.radius),
                    ),
                  ),
                ),
                _pickedBar(context, catalogRow: false),
                if (widget.pendingOrder) _orderBar(context)
                else if (widget.onReopenPicker != null) _reopenPickBar(context)
                else if (widget.actionLinks.isNotEmpty) _linkBar(context),
                SimpleDock(
                  spec: spec,
                  phase: phase,
                  level: widget.micLevel,
                  continuous: widget.continuous,
                  onMicTap: state == _SimpleState.thinking ? null : widget.onMicTap,
                  onMicLongPress: widget.onMicLongPress,
                  onCatalog: widget.onPick,
                  onKeyboard: widget.onBackToChat,
                  sideEnabled: !widget.isLoading && !widget.isRecording,
                ),
              ]);
            }),
          ),
        );
      }),
      ),
    );
  }

  // ══════════════════════════════════════════════════════
  // 整體版面
  // ══════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (!widget.voiceAvailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.mic_off_rounded, size: 64, color: cs.outline),
            const SizedBox(height: 16),
            Text('這台裝置無法使用語音', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('簡易模式需要麥克風與語音辨識（Android、Chrome、Edge）',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.outline)),
            const SizedBox(height: 24),
            FilledButton.tonal(
                onPressed: widget.onBackToChat,
                child: const Text('回到聊天模式')),
          ]),
        ),
      );
    }

    // A～D 風格：新版面；傳統：下面原本的版面，完全不變
    if (widget.style != SimpleStyle.classic) return _buildStyled(context);

    final state = _state;
    return SafeArea(
      top: false,
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= _wideBreakpoint;
        const footerH = 72.0;

        final Widget body;
        if (wide) {
          // 寬螢幕：左 4 兩格上下排 / 右 6 文字對話
          body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 0, 16),
                child: Column(children: [
                  Expanded(child: _aiTile(context, state, compact: false)),
                  const SizedBox(height: 16),
                  Expanded(child: _userTile(context, state, compact: false)),
                ]),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 6,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                child: DockRegion(
                  controller: GetIt.instance<CabinetWebController>(),
                  child: _transcriptPanel(context, state, compact: false),
                ),
              ),
            ),
          ]);
        } else {
          // 手機：兩格並排在上（高度依螢幕縮放），下面全部給文字對話
          final tileH =
              ((box.maxHeight - footerH) * 0.4).clamp(140.0, 214.0).toDouble();
          body = Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: SizedBox(
                height: tileH,
                child: Row(children: [
                  Expanded(child: _aiTile(context, state, compact: true)),
                  const SizedBox(width: 10),
                  Expanded(child: _userTile(context, state, compact: true)),
                ]),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: DockRegion(
                  controller: GetIt.instance<CabinetWebController>(),
                  child: _transcriptPanel(context, state, compact: true),
                ),
              ),
            ),
          ]);
        }

        return Column(children: [
          Expanded(child: body),
          _pickedBar(context),
          if (widget.pendingOrder) _orderBar(context)
          else if (widget.onReopenPicker != null) _reopenPickBar(context)
          else if (widget.actionLinks.isNotEmpty) _linkBar(context),
          // ── Footer：全功能模式／端點／聊天模式 ─────────────
          Container(
            height: footerH,
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(top: BorderSide(color: cs.outlineVariant)),
            ),
            child: _buildShortcutRow(context,
                editable: state == _SimpleState.idle, compact: true),
          ),
        ]);
      }),
    );
  }

  // ══════════════════════════════════════════════════════
  // 兩格：外框、標籤、狀態、字幕
  // ══════════════════════════════════════════════════════
  Widget _tile({
    required BuildContext context,
    required bool compact,
    required bool active,
    required bool dimmed,
    required Color activeColor,
    required String label,
    required String chip,
    required Color chipBg,
    required Color chipFg,
    required String semantics,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
    required Widget Function(double size) visual,
    required Widget caption,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final radius = BorderRadius.circular(compact ? 20 : 24);
    final captionLines = 2;
    final captionSize = compact ? 14.0 : 17.0;
    final captionH = captionSize * 1.5 * captionLines;

    return Semantics(
      button: onTap != null,
      label: semantics,
      child: AnimatedOpacity(
        opacity: dimmed ? 0.55 : 1,
        duration: const Duration(milliseconds: 250),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: cs.surfaceContainer,
            borderRadius: radius,
            border: Border.all(
                color: active ? activeColor : cs.outlineVariant, width: 2),
            boxShadow: active
                ? [
                    BoxShadow(
                        color: activeColor.withValues(alpha: 0.25),
                        blurRadius: 24,
                        spreadRadius: 1),
                  ]
                : const [],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: onTap,
              onLongPress: onLongPress,
              child: Stack(children: [
                Positioned(
                  top: compact ? 10 : 14,
                  left: compact ? 12 : 16,
                  child: Text(label,
                      style: TextStyle(
                          fontSize: compact ? 12 : 13,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurfaceVariant)),
                ),
                Positioned(
                  top: compact ? 8 : 12,
                  right: compact ? 8 : 14,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    padding: EdgeInsets.symmetric(
                        horizontal: compact ? 8 : 10, vertical: 2),
                    decoration: BoxDecoration(
                        color: chipBg,
                        borderRadius: BorderRadius.circular(999)),
                    child: Text(chip,
                        style: TextStyle(
                            fontSize: compact ? 11 : 12,
                            fontWeight: FontWeight.w500,
                            color: chipFg)),
                  ),
                ),
                // 動畫 + 字幕：依格子高度決定動畫大小，矮的螢幕也放得下
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(compact ? 10 : 24,
                        compact ? 34 : 40, compact ? 10 : 24, compact ? 10 : 18),
                    child: LayoutBuilder(builder: (context, c) {
                      final gap = compact ? 12.0 : 18.0;
                      final maxVisual = compact ? 80.0 : 112.0;
                      final size = (c.maxHeight - captionH - gap)
                          .clamp(36.0, maxVisual)
                          .toDouble();
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                              width: size, height: size, child: visual(size)),
                          SizedBox(height: gap),
                          SizedBox(
                            width: double.infinity,
                            height: captionH,
                            child: DefaultTextStyle.merge(
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: captionSize, height: 1.5),
                              child: caption,
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// 字幕：最多兩行，超過時顯示最新的部分（邊說邊出字時才看得到最後幾個字）
  Widget _caption(String text, Color color) {
    return SingleChildScrollView(
      reverse: true,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(text, style: TextStyle(color: color)),
    );
  }

  Widget _aiTile(BuildContext context, _SimpleState state,
      {required bool compact}) {
    final cs = Theme.of(context).colorScheme;
    final thinking = state == _SimpleState.thinking;
    final speaking = state == _SimpleState.speaking;
    final active = thinking || speaking;
    final reply = widget.replyText.trim();

    final caption = thinking
        ? (widget.progressText ?? '正在查詢資料…')
        : reply.isNotEmpty
            ? reply
            : '回答時點這裡可以打斷';

    return _tile(
      context: context,
      compact: compact,
      active: active,
      dimmed: state == _SimpleState.listening,
      activeColor: cs.primary,
      label: 'AI 助理',
      chip: thinking ? '思考中' : speaking ? '回答中' : '待命',
      chipBg: active ? cs.primaryContainer : cs.surfaceContainerHighest,
      chipFg: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
      semantics: 'AI 助理，回答時點這裡可以打斷',
      onTap: speaking ? widget.onMicTap : null,
      visual: (size) => _aiOrb(context, state, size),
      caption: _caption(
          caption, reply.isEmpty && !thinking ? cs.outline : cs.onSurface),
    );
  }

  Widget _userTile(BuildContext context, _SimpleState state,
      {required bool compact}) {
    final cs = Theme.of(context).colorScheme;
    final listening = state == _SimpleState.listening;
    final heard = widget.heardText.trim();

    final caption = heard.isNotEmpty
        ? heard
        : listening
            ? (widget.continuous ? '請說話…（沒開口時點一下結束連續對話）' : '請說話…')
            : (widget.continuous ? '點這裡開始連續對話，長按可設定' : '點這裡開始說話，長按可設定');

    return _tile(
      context: context,
      compact: compact,
      active: listening,
      dimmed: state == _SimpleState.thinking || state == _SimpleState.speaking,
      activeColor: cs.error,
      label: widget.continuous ? '你・連續對話' : '你',
      chip: listening ? '聆聽中' : '點我說話',
      chipBg: listening ? cs.errorContainer : cs.surfaceContainerHighest,
      chipFg: listening ? cs.onErrorContainer : cs.onSurfaceVariant,
      semantics: '你，點這裡開始或結束說話，長按打開連續對話設定',
      onTap: state == _SimpleState.thinking ? null : widget.onMicTap,
      onLongPress: widget.onMicLongPress,
      visual: (size) => _userMic(context, state, size),
      caption: _caption(caption, heard.isEmpty ? cs.outline : cs.onSurface),
    );
  }

  // ══════════════════════════════════════════════════════
  // 動畫：AI 圓球、你的麥克風
  // ══════════════════════════════════════════════════════
  /// AI：閒置呼吸、思考時外圈旋轉、回答時擴散波紋 + 聲音長條跳動
  Widget _aiOrb(BuildContext context, _SimpleState state, double size) {
    final cs = Theme.of(context).colorScheme;
    final thinking = state == _SimpleState.thinking;
    final speaking = state == _SimpleState.speaking;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = _pulse.value;
        final breathe =
            state == _SimpleState.idle ? 1 + math.sin(t * 2 * math.pi) * 0.04 : 1.0;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            if (speaking)
              for (final phase in [0.0, 0.5])
                Builder(builder: (_) {
                  final p = (t + phase) % 1;
                  return Container(
                    width: size * (1 + p * 0.7),
                    height: size * (1 + p * 0.7),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cs.primary.withValues(alpha: (1 - p) * 0.3),
                    ),
                  );
                }),
            if (thinking)
              SizedBox(
                width: size + 14,
                height: size + 14,
                child: CircularProgressIndicator(
                    strokeWidth: 3, color: cs.primary),
              ),
            Transform.scale(
              scale: breathe,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.primaryContainer,
                  border: Border.all(color: cs.primary, width: 2),
                ),
                alignment: Alignment.center,
                child: speaking
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < 5; i++) ...[
                            if (i > 0) SizedBox(width: size * 0.05),
                            Container(
                              width: size * 0.065,
                              height: size *
                                  (0.12 +
                                      0.3 *
                                          math
                                              .sin(t * 2 * math.pi * 3 + i * 1.3)
                                              .abs()) *
                                  (i == 2 ? 1.3 : i == 1 || i == 3 ? 1.1 : 0.85),
                              decoration: BoxDecoration(
                                color: cs.onPrimaryContainer,
                                borderRadius: BorderRadius.circular(size),
                              ),
                            ),
                          ],
                        ],
                      )
                    : Icon(Icons.auto_awesome_rounded,
                        size: size * 0.42, color: cs.onPrimaryContainer),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 你：麥克風，聆聽時波紋跟著說話音量放大縮小
  Widget _userMic(BuildContext context, _SimpleState state, double size) {
    final cs = Theme.of(context).colorScheme;
    final listening = state == _SimpleState.listening;
    final micD = size * 0.9;
    final bg = listening ? cs.error : cs.primary;
    final fg = listening ? cs.onError : cs.onPrimary;

    return AnimatedBuilder(
      animation: widget.micLevel,
      builder: (context, _) {
        final level = listening ? widget.micLevel.value : 0.0;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            if (listening) ...[
              AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: micD + 8 + level * micD * 0.6,
                height: micD + 8 + level * micD * 0.6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bg.withValues(alpha: 0.14 + level * 0.16),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: micD + 2 + level * micD * 0.32,
                height: micD + 2 + level * micD * 0.32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bg.withValues(alpha: 0.22 + level * 0.18),
                ),
              ),
            ],
            Transform.scale(
              scale: 1 + level * 0.08,
              child: Container(
                width: micD,
                height: micD,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bg,
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black26, blurRadius: 10, offset: Offset(0, 3)),
                  ],
                ),
                child: Icon(
                    state == _SimpleState.speaking
                        ? Icons.mic_none_rounded
                        : Icons.mic_rounded,
                    size: micD * 0.44,
                    color: fg),
              ),
            ),
          ],
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════
  // 文字對話（即時更新）
  // ══════════════════════════════════════════════════════
  Widget _transcriptPanel(BuildContext context, _SimpleState state,
      {required bool compact, double? radius}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // 對話紀錄 + 正在進行的這一輪（邊說邊出字、思考中、唸到哪顯示到哪）
    final items = <_TItem>[
      for (final m in widget.messages)
        _TItem(
            text: m.text,
            isUser: m.isUser,
            isError: m.isError,
            time: m.time,
            msg: m),
    ];
    final heard = widget.heardText.trim();
    if (state == _SimpleState.listening) {
      items.add(_TItem(text: heard, isUser: true, live: true));
    } else if (state == _SimpleState.thinking) {
      items.add(const _TItem(text: '', isUser: false, dots: true));
    } else if (state == _SimpleState.speaking &&
        items.isNotEmpty &&
        !items.last.isUser) {
      items[items.length - 1] = _TItem(
          text: widget.replyText, isUser: false, live: true, time: items.last.time);
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius ?? (compact ? 18 : 20)),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(children: [
        SizedBox(
          height: compact ? 44 : 52,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 20),
            child: Row(children: [
              Icon(Icons.forum_outlined,
                  size: compact ? 16 : 18, color: cs.primary),
              const SizedBox(width: 8),
              Text('文字對話',
                  style: TextStyle(
                      fontSize: compact ? 14 : 15,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('${widget.messages.length} 則',
                  style: TextStyle(
                      fontSize: compact ? 12 : 13, color: cs.outline)),
            ]),
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant),
        Expanded(
          child: _TranscriptList(
              items: items,
              fontSize: compact ? 15 : 17,
              compact: compact,
              onLongPressUser: widget.onEditMessage),
        ),
      ]),
    );
  }

  /// 新訂單等確認：確認建立／修改
  /// 工具給的連結（例如「更新詢單」）：按了才開，不自動彈出
  Widget _linkBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        for (final l in widget.actionLinks)
          FilledButton.tonalIcon(
            onPressed: () => openLink(l.url),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text('開啟：${l.label}'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              textStyle: const TextStyle(fontSize: 14),
            ),
          ),
      ]),
    );
  }

  /// AI 請使用者挑選櫃子：挑選畫面被關掉時，從這裡重新打開
  Widget _reopenPickBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: FilledButton.tonalIcon(
        onPressed: widget.onReopenPicker,
        icon: const Icon(Icons.view_list_rounded, size: 20),
        label: const Text('重新開啟挑選畫面'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          textStyle: const TextStyle(fontSize: 15),
        ),
      ),
    );
  }

  Widget _orderBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(children: [
        Icon(Icons.receipt_long_rounded, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text('新訂單等你確認',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: cs.onSurface)),
        ),
        OutlinedButton(
          onPressed: widget.onEditOrder,
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('修改'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: widget.onConfirmOrder,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          icon: const Icon(Icons.check_circle_rounded, size: 18),
          label: const Text('確認建立'),
        ),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════
  // Footer 快捷鈕
  // ══════════════════════════════════════════════════════
  Widget _buildShortcutRow(BuildContext context,
      {required bool editable, required bool compact}) {
    final primary = Theme.of(context).colorScheme.primary;
    return AnimatedOpacity(
      opacity: editable ? 1 : 0.4,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !editable,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: _ShortcutIconItem(
                compact: compact,
                leading: Text(widget.skillIcon,
                    style: const TextStyle(fontSize: 18)),
                label: widget.skillName,
                onTap: widget.onPickSkill,
              ),
            ),
            Expanded(
              child: _ShortcutIconItem(
                compact: compact,
                leading: Icon(Icons.dns_outlined, color: primary),
                label: widget.endpointName,
                onTap: widget.onOpenSettings,
              ),
            ),
            Expanded(
              child: _ShortcutIconItem(
                compact: compact,
                leading:
                    Icon(Icons.chat_bubble_outline_rounded, color: primary),
                label: '聊天模式',
                onTap: widget.onBackToChat,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ShortcutIconItem extends StatelessWidget {
  const _ShortcutIconItem({
    required this.leading,
    required this.label,
    required this.onTap,
    this.compact = false,
  });

  final Widget leading;
  final String label;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = compact ? 40.0 : 48.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 4 : 8, horizontal: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: leading,
          ),
          SizedBox(height: compact ? 4 : 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

/// 文字對話的一則（含正在進行中的這一輪）
class _TItem {
  final String text;
  final bool isUser;
  final bool isError;
  final bool live; // 正在說／正在唸：純文字 + 游標
  final bool dots; // AI 思考中
  final DateTime? time;
  final ChatMessage? msg; // 對應的訊息（正在進行中的這一輪沒有）
  const _TItem({
    required this.text,
    required this.isUser,
    this.isError = false,
    this.live = false,
    this.dots = false,
    this.time,
    this.msg,
  });
}

/// 文字對話列表：使用者在右、助理在左，永遠停在最新一則
class _TranscriptList extends StatelessWidget {
  final List<_TItem> items;
  final double fontSize;
  final bool compact;
  final void Function(ChatMessage)? onLongPressUser; // 長按自己說過的話
  const _TranscriptList({
    required this.items,
    required this.fontSize,
    required this.compact,
    this.onLongPressUser,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Center(
        child: Text('還沒有對話，點「你」開始說話',
            style: TextStyle(color: cs.outline)),
      );
    }
    return ListView.builder(
      reverse: true, // 停在最新一則
      padding: EdgeInsets.all(compact ? 12 : 20),
      itemCount: items.length,
      itemBuilder: (context, i) => _item(context, items[items.length - 1 - i]),
    );
  }

  Widget _item(BuildContext context, _TItem m) {
    if (m.dots) return const _TypingIndicator();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = m.isUser
        ? cs.onPrimary
        : m.isError
            ? cs.onErrorContainer
            : cs.onSurface;
    final style = TextStyle(fontSize: fontSize, height: 1.6, color: fg);
    final time = m.time == null
        ? null
        : '${m.time!.hour.toString().padLeft(2, '0')}:'
            '${m.time!.minute.toString().padLeft(2, '0')}';

    final Widget content = m.live
        // 正在說／正在唸：純文字 + 游標
        ? Text.rich(TextSpan(style: style, children: [
            TextSpan(text: m.text),
            TextSpan(
                text: '▍',
                style: TextStyle(
                    color: m.isUser ? cs.onPrimary : cs.primary)),
          ]))
        : m.isUser
            ? Text(m.text, style: style)
            : MarkdownBody(
                data: m.text,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(theme)
                    .copyWith(p: style),
              );

    return Align(
      alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: m.isUser ? 0.8 : 0.88,
        alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Align(
          alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            onLongPress: (m.isUser && m.msg != null && onLongPressUser != null)
                ? () => onLongPressUser!(m.msg!)
                : null,
            child: Container(
              margin: EdgeInsets.symmetric(vertical: compact ? 4 : 6),
              padding: EdgeInsets.fromLTRB(
                  compact ? 13 : 16, compact ? 8 : 10, compact ? 13 : 16, 6),
              decoration: BoxDecoration(
                color: m.isUser
                    ? cs.primary
                    : m.isError
                        ? cs.errorContainer
                        : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(m.isUser ? 18 : 6),
                  bottomRight: Radius.circular(m.isUser ? 6 : 18),
                ),
              ),
              child: Column(
                crossAxisAlignment: m.isUser
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  content,
                  if (time != null) ...[
                    const SizedBox(height: 2),
                    Text(time,
                        style: TextStyle(
                            fontSize: 10, color: fg.withValues(alpha: 0.6))),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 只給測試用：直接建出簡易畫面。
@visibleForTesting
Widget buildSimpleViewForTest({
  required List<PickedItem> picked,
  required List<ChatMessage> messages,
  SimpleStyle style = SimpleStyle.classic,
  bool isRecording = false,
  bool isLoading = false,
  bool isSpeaking = false,
  bool continuous = false,
  VoidCallback? onMicTap,
  VoidCallback? onMicLongPress,
  VoidCallback? onPick,
  VoidCallback? onBackToChat,
}) =>
    _SimpleVoiceView(
      voiceAvailable: true,
      isRecording: isRecording,
      isLoading: isLoading,
      isSpeaking: isSpeaking,
      style: style,
      continuous: continuous,
      onMicLongPress: onMicLongPress,
      heardText: isRecording ? '女兒房的 A01-1 改兩個' : '',
      replyText: isSpeaking ? '好的，已改成 2 個' : '',
      micLevel: ValueNotifier<double>(isRecording ? 0.6 : 0),
      messages: messages,
      skillIcon: '🗄️',
      skillName: 'x',
      endpointName: 'y',
      onMicTap: onMicTap ?? () {},
      onBackToChat: onBackToChat ?? () {},
      onPickSkill: () {},
      onOpenSettings: () {},
      progressText: null,
      pendingOrder: false,
      onConfirmOrder: () {},
      onEditOrder: () {},
      picked: picked,
      onPick: onPick ?? () {},
      onSendPicked: () {},
      onRemovePicked: (_) {},
      onPickedQty: (_, __) {},
    );
