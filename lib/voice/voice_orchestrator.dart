import '../services/chat_orchestrator.dart';
import 'voice_input.dart';
import 'mobile_voice_output.dart';
import 'voice_mode.dart';

class VoiceOrchestrator {
  final VoiceInput        _input;
  final MobileVoiceOutput _output;
  final ChatOrchestrator  _chat;
  VoiceMode _mode = VoiceMode.disabled;

  /// 辨識出文字後先問這個：回傳 true 表示已經由別人處理（例如交給開著的網頁視窗操作畫面），
  /// 就不送給 AI。
  Future<bool> Function(String text)? interceptTranscript;

  void Function(String)?  onTranscribed;
  void Function(String)?  onPartialTranscript;
  void Function(double)?  onMicLevel; // 說話音量 0 ~ 1
  void Function(String)?  onResponse;
  void Function(String)?  onError;
  void Function(bool)?    onRecordingChanged;
  void Function(bool)?    onSpeakingChanged;
  /// 準備開始唸：要唸的完整文字（已去掉 Markdown 符號）
  void Function(String)?  onSpeakText;
  /// 唸到第幾個字
  void Function(int)?     onSpeakProgress;

  VoiceOrchestrator(this._input, this._output, this._chat) {
    _input.onPartial = (t) => onPartialTranscript?.call(t);
    _input.onLevel = (l) => onMicLevel?.call(l);
    _output.onProgress = (end) => onSpeakProgress?.call(end);
  }

  VoiceMode get currentMode => _mode;

  /// 語音輸入是否就緒（代理 _input.isReady）
  bool get isReady => _input.isReady;

  Future<void> initialize() async {
    await _input.initialize();
    await _output.initialize();
  }

  Future<void> setMode(VoiceMode mode) async => _mode = mode;

  /// PTT 開始錄音
  Future<void> startPTT() async {
    if (!_input.isReady) {
      onError?.call('麥克風權限未開啟，請至設定開啟');
      return;
    }
    await _input.startRecording();
    onRecordingChanged?.call(true);
  }

  /// PTT 停止並辨識送出
  Future<void> stopPTTAndSend() async {
    onRecordingChanged?.call(false);
    final text = await _input.stopAndTranscribe();
    if (text == null || text.trim().isEmpty) {
      onError?.call(_input.lastError ?? '未能辨識語音，請再試一次');
      return;
    }
    if (await _intercepted(text)) return;
    onTranscribed?.call(text);
    await _processText(text);
  }

  /// 聊天模式口述：開始錄音，說話的文字透過 [onPartialTranscript] 即時回傳，
  /// 放開後用 [stopDictation] 取得最終文字。不會自動送給 AI，由使用者看過、修改後自己按送出。
  Future<void> startDictation() async {
    if (!_input.isReady) {
      onError?.call('麥克風權限未開啟，請至設定開啟');
      return;
    }
    await _output.stop();
    await _input.startRecording();
    onRecordingChanged?.call(true);
  }

  /// 停止口述，回傳最終辨識文字（沒聽到回 null）
  Future<String?> stopDictation() async {
    onMicLevel?.call(0);
    onRecordingChanged?.call(false);
    final text = await _input.stopAndTranscribe();
    if (text == null || text.trim().isEmpty) {
      onError?.call(_input.lastError ?? '沒有聽到內容，請再說一次');
      return null;
    }
    return text.trim();
  }

  /// 簡易模式：點一下開始聽，停頓後自動結束（或呼叫 [stopTurn]），
  /// 辨識完送給 AI 並唸出回覆
  Future<void> startTurn() async {
    if (!_input.isReady) {
      onError?.call('麥克風權限未開啟，請至設定開啟');
      return;
    }
    await _output.stop();
    await _input.startRecording();
    onRecordingChanged?.call(true);
    final text = await _input.awaitResult();
    onMicLevel?.call(0);
    onRecordingChanged?.call(false);
    if (text == null) {
      onError?.call(_input.lastError ?? '沒有聽到內容，請再說一次');
      return;
    }
    if (await _intercepted(text)) return;
    onTranscribed?.call(text);
    await _processText(text);
  }

  /// 簡易模式：手動結束錄音，結果交給 [startTurn] 處理
  Future<void> stopTurn() => _input.stopListening();

  Future<bool> _intercepted(String text) async {
    final f = interceptTranscript;
    if (f == null) return false;
    try {
      return await f(text);
    } catch (_) {
      return false;
    }
  }

  Future<void> _processText(String text) async {
    try {
      // ✅ 解構 Record，語音只需要 content，toolsUsed 忽略
      final (:content, toolsUsed: _) = await _chat.sendMessageAsync(text, voice: true);
      onResponse?.call(content);
      await speakReply(content);
    } catch (e) {
      onError?.call('處理失敗：$e');
    } finally {
      onSpeakingChanged?.call(false);
    }
  }

  /// 語速（0.1 ~ 1.0，0.5 = 正常），下一句開始生效
  double get speechRate => _output.rate;
  Future<void> setSpeechRate(double value) => _output.setRate(value);

  /// 語音回覆開關（右上角音量按鈕）；關掉時只顯示文字
  bool speakReplies = true;

  /// 唸出 AI 回覆（語音或打字都會用到）。關掉語音回覆時直接顯示完整文字。
  Future<void> speakReply(String content) async {
    final clean = _output.cleanForSpeech(content);
    onSpeakText?.call(clean);
    if (!speakReplies || clean.isEmpty) {
      onSpeakingChanged?.call(false);
      return;
    }
    onSpeakingChanged?.call(true);
    try {
      await _output.speak(content);
    } finally {
      onSpeakingChanged?.call(false);
    }
  }

  Future<void> stopSpeaking() async {
    await _output.stop();
    onSpeakingChanged?.call(false);
  }

  Future<void> dispose() async {
    await _input.dispose();
    await _output.dispose();
  }
}
