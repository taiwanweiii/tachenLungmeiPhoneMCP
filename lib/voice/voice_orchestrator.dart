import 'dart:async';

import '../services/chat_orchestrator.dart';
import 'voice_input.dart';
import 'voice_settings.dart';
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

  /// 語音送給 AI 時，另外附上只給模型看的備註（例如目前已選的櫃子與規格）。回傳 null 就不附。
  String? Function()? aiNoteProvider;

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

  /// 連續對話、停頓秒數、插話關鍵字（聊天頁載入後設定）
  VoiceConversationSettings settings = VoiceConversationSettings();

  /// 連續對話時一直沒開口，自動暫停了
  void Function()? onPaused;

  /// AI 講話中聽到插話關鍵字，已經打斷 AI、改聽使用者
  void Function()? onBargeIn;

  bool _inLoop = false;
  bool _loopStopped = true;
  String _lastPartial = '';
  // AI 講話中邊聽邊找插話關鍵字
  bool _bargeWatching = false;
  bool _bargeHit = false;
  String _bargeSpeaking = '';

  VoiceOrchestrator(this._input, this._output, this._chat) {
    _input.onPartial = (t) {
      _lastPartial = t;
      // AI 講話中聽到的大多是喇叭回音：只拿來找關鍵字，不顯示
      if (_bargeWatching) {
        _onBargePartial(t);
        return;
      }
      onPartialTranscript?.call(t);
    };
    _input.onLevel = (l) {
      if (_bargeWatching && !_bargeHit) return; // 回音的音量不要讓麥克風動畫跳
      onMicLevel?.call(l);
    };
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
    await _input.startRecording(
        options: ListenOptions(endSilenceSeconds: settings.endSilenceSeconds));
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
    await _input.startRecording(
        options: ListenOptions(endSilenceSeconds: settings.endSilenceSeconds));
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
  /// 辨識完送給 AI 並唸出回覆。
  ///
  /// 開了連續對話（[settings]）：AI 講完自動再聽，直到一直沒開口 [VoiceConversationSettings.idleSeconds]
  /// 秒（呼叫 [onPaused]）或 [stopLoop]。有設插話關鍵字時，AI 講話中說出關鍵字就打斷 AI 改聽使用者。
  Future<void> startTurn() async {
    if (!_input.isReady) {
      onError?.call('麥克風權限未開啟，請至設定開啟');
      return;
    }
    if (_inLoop) return;
    _inLoop = true;
    _loopStopped = false;
    try {
      await _turnLoop();
    } finally {
      _inLoop = false;
    }
  }

  Future<void> _turnLoop() async {
    String? carried; // 插話時關鍵字後面已經講的話
    while (!_loopStopped) {
      var text = carried;
      carried = null;
      if (text == null) {
        text = await _listenOnce();
        if (_loopStopped) return;
        if (text == null) {
          if (settings.continuous) {
            onPaused?.call();
          } else {
            onError?.call(_input.lastError ?? '沒有聽到內容，請再說一次');
          }
          return;
        }
      }
      if (!await _intercepted(text)) {
        onTranscribed?.call(text);
        final barged = await _processText(text, bargeIn: settings.bargeInEnabled);
        if (barged != null && barged.isNotEmpty) carried = barged;
      }
      if (!settings.continuous) return;
    }
  }

  /// 聽一句（講完停頓、或一直沒開口就結束）
  Future<String?> _listenOnce() async {
    await _output.stop();
    _lastPartial = '';
    await _input.startRecording(
        options: ListenOptions(
      endSilenceSeconds: settings.endSilenceSeconds,
      idleSeconds: settings.idleSeconds,
    ));
    onRecordingChanged?.call(true);
    final text = await _input.awaitResult();
    onMicLevel?.call(0);
    onRecordingChanged?.call(false);
    return text;
  }

  /// 簡易模式：手動結束錄音，結果交給 [startTurn] 處理
  Future<void> stopTurn() => _input.stopListening();

  /// 結束連續對話：停止聽、停止唸，不再自動開始下一句
  Future<void> stopLoop() async {
    _loopStopped = true;
    await _input.cancel();
    await _output.stop();
  }

  /// 連續對話中正在跑（聽、想、唸都算）
  bool get inLoop => _inLoop;

  /// AI 講話時邊聽邊找插話關鍵字；找到就停止唸、接著聽使用者講完。
  /// 回傳：沒插話 null；插話了回關鍵字後面講的話（只說關鍵字就是空字串）。
  Future<String?> _speakWithBargeIn(String content) async {
    final clean = _output.cleanForSpeech(content);
    onSpeakText?.call(clean);
    if (!speakReplies || clean.isEmpty) {
      onSpeakingChanged?.call(false);
      return null;
    }
    onSpeakingChanged?.call(true);
    _bargeSpeaking = clean;
    _bargeHit = false;
    _bargeWatching = true;
    var speakingDone = false;
    String? heardAfter;

    final listen = () async {
      while (!speakingDone && !_loopStopped && !_bargeHit) {
        _lastPartial = '';
        // 不因安靜自動結束：AI 講話的停頓不能讓它收音
        await _input.startRecording(options: const ListenOptions(autoStop: false));
        final result = _input.awaitResult();
        // AI 唸完（或使用者結束對話）還沒插話：取消這次聽。原生端可能還在啟動，所以重試到結束
        while (true) {
          final done = await Future.any([
            result.then((_) => true),
            Future<bool>.delayed(const Duration(milliseconds: 300), () => false),
          ]);
          if (done) break;
          if ((speakingDone || _loopStopped) && !_bargeHit) await _input.cancel();
        }
        final t = await result;
        if (_bargeHit) {
          heardAfter = matchBargeIn(t ?? _lastPartial, settings.keywords,
                  speaking: _bargeSpeaking) ??
              '';
          return;
        }
        // 自己結束了（例如 iOS 一次最多聽約 1 分鐘）：AI 還在唸就再開一次
        if (!speakingDone) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }();

    try {
      await _output.speak(content);
    } finally {
      speakingDone = true;
      onSpeakingChanged?.call(false);
    }
    await listen;
    _bargeWatching = false;
    if (_bargeHit) {
      onMicLevel?.call(0);
      onRecordingChanged?.call(false);
      return heardAfter ?? '';
    }
    return null;
  }

  /// AI 講話中收到的字：找插話關鍵字（不顯示，大部分是喇叭的回音）
  void _onBargePartial(String text) {
    final rest = matchBargeIn(text, settings.keywords, speaking: _bargeSpeaking);
    if (rest == null) return;
    if (!_bargeHit) {
      _bargeHit = true;
      // 打斷 AI，接著聽使用者講完
      unawaited(_output.stop());
      unawaited(_input.armAutoStop(settings.endSilenceSeconds));
      onBargeIn?.call();
      onRecordingChanged?.call(true);
    }
    onPartialTranscript?.call(rest);
  }

  Future<bool> _intercepted(String text) async {
    final f = interceptTranscript;
    if (f == null) return false;
    try {
      return await f(text);
    } catch (_) {
      return false;
    }
  }

  /// 送給 AI 並唸出回覆。[bargeIn]：唸的時候可以用關鍵字插話，回傳插話後講的話（沒插話回 null）
  Future<String?> _processText(String text, {bool bargeIn = false}) async {
    try {
      // ✅ 解構 Record，語音只需要 content，toolsUsed 忽略
      final (:content, toolsUsed: _) = await _chat.sendMessageAsync(text, voice: true, aiNote: aiNoteProvider?.call());
      onResponse?.call(content);
      if (bargeIn) return await _speakWithBargeIn(content);
      await speakReply(content);
      return null;
    } catch (e) {
      onError?.call('處理失敗：$e');
      return null;
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
