import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 裝置上可用的一個語音
class TtsVoice {
  final String name;
  final String locale;
  const TtsVoice({required this.name, required this.locale});

  String get _n => name.toLowerCase();
  String get _l => locale.toLowerCase().replaceAll('_', '-');

  bool get isNatural => _n.contains('natural') || _n.contains('neural');
  bool get isOnline =>
      _n.contains('online') || _n.contains('network') || _n.contains('google');
  bool get isCantonese => _l.contains('hk') || _l.startsWith('yue');

  /// 自動挑選用：台灣中文、神經網路／線上語音優先
  int get score {
    var s = 0;
    if (_l.contains('tw')) {
      s += 100;
    } else if (isCantonese) {
      s -= 30;
    } else {
      s += 40;
    }
    if (isNatural) s += 50;
    if (_n.contains('online')) s += 20;
    if (_n.contains('google')) s += 25;
    if (_n.contains('network')) s += 15;
    return s;
  }

  String encode() => '$name|$locale';
  static TtsVoice? decode(String? s) {
    if (s == null || !s.contains('|')) return null;
    final i = s.lastIndexOf('|');
    return TtsVoice(name: s.substring(0, i), locale: s.substring(i + 1));
  }
}

class MobileVoiceOutput {
  final FlutterTts _tts = FlutterTts();
  final String language;
  bool _speaking = false;

  bool get isSpeaking => _speaking;

  /// 語速：統一用 Android 的刻度（0.1 ~ 1.0，0.5 = 正常）。
  /// Web 的刻度不同（1.0 = 正常），設定時自動乘以 2。
  double _rate = 0.5;
  double get rate => _rate;

  Future<void> setRate(double value) async {
    _rate = (value.clamp(0.1, 1.0) * 10).round() / 10;
    try {
      await _tts.setSpeechRate(kIsWeb ? _rate * 2 : _rate);
    } catch (_) {}
  }

  /// 音調：0.5 ~ 2.0（1.0 = 正常）
  double _pitch = 1.0;
  double get pitch => _pitch;

  Future<void> setPitch(double value) async {
    _pitch = (value.clamp(0.5, 2.0) * 10).round() / 10;
    try {
      await _tts.setPitch(_pitch);
    } catch (_) {}
  }

  /// 選擇的聲音；null = 自動挑最自然的
  TtsVoice? _voiceChoice;
  TtsVoice? get voiceChoice => _voiceChoice;

  /// 實際在用的聲音（自動時是挑出來的那個）
  TtsVoice? _activeVoice;
  TtsVoice? get activeVoice => _activeVoice;

  Future<void> setVoice(TtsVoice? voice) async {
    _voiceChoice = voice;
    await _applyVoice();
  }

  Future<void> _applyVoice() async {
    try {
      var v = _voiceChoice;
      if (v == null) {
        final all = await listVoices();
        if (all.isEmpty) return;
        v = all.first;
      }
      await _tts.setVoice({'name': v.name, 'locale': v.locale});
      _activeVoice = v;
    } catch (e) {
      debugPrint('🔇 設定語音失敗：$e');
    }
  }

  /// 這台裝置的中文語音，最自然的排前面
  Future<List<TtsVoice>> listVoices() async {
    List raw = const [];
    // Web 的語音清單會晚一點才載入，空的話等一下再試
    for (var i = 0; i < 4 && raw.isEmpty; i++) {
      if (i > 0) await Future.delayed(const Duration(milliseconds: 400));
      try {
        raw = (await _tts.getVoices as List?) ?? const [];
      } catch (_) {}
    }
    final seen = <String>{};
    final list = <TtsVoice>[];
    for (final v in raw) {
      if (v is! Map) continue;
      final name = '${v['name'] ?? ''}';
      final locale = '${v['locale'] ?? ''}';
      final l = locale.toLowerCase().replaceAll('_', '-');
      if (name.isEmpty) continue;
      if (!(l.startsWith('zh') || l.startsWith('cmn') || l.startsWith('yue'))) {
        continue;
      }
      if (seen.add(name)) list.add(TtsVoice(name: name, locale: locale));
    }
    list.sort((a, b) => b.score.compareTo(a.score));
    return list;
  }

  /// 試聽：打斷目前的語音，唸一句範例
  Future<void> preview(String text) async {
    await stop();
    unawaited(speak(text));
  }

  // ── 記住設定 ──────────────────────────────────────────
  static const _kRate = 'tts_rate';
  static const _kPitch = 'tts_pitch';
  static const _kVoice = 'tts_voice';

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await setRate(prefs.getDouble(_kRate) ?? 0.5);
      await setPitch(prefs.getDouble(_kPitch) ?? 1.0);
      await setVoice(TtsVoice.decode(prefs.getString(_kVoice)));
    } catch (_) {}
  }

  Future<void> saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kRate, _rate);
      await prefs.setDouble(_kPitch, _pitch);
      await prefs.setString(_kVoice, _voiceChoice?.encode() ?? '');
    } catch (_) {}
  }

  /// 唸到第幾個字（對應 [cleanForSpeech] 後的文字），平台支援才會呼叫
  void Function(int end)? onProgress;

  MobileVoiceOutput({this.language = 'zh-TW'});

  Future<void> initialize() async {
    await _tts.setLanguage(language);
    await setRate(_rate);
    await _tts.setVolume(1.0);
    await setPitch(_pitch);
    // 不用套件的 awaitSpeakCompletion：Web 版出錯或被中斷時永遠不會回傳，
    // 畫面會卡在「回答中」。改成自己用 Completer 判斷什麼時候唸完。
    await _tts.awaitSpeakCompletion(false);

    _tts.setStartHandler(() => _speaking = true);
    _tts.setCompletionHandler(_finish);
    _tts.setCancelHandler(_finish);
    _tts.setErrorHandler((msg) {
      debugPrint('🔇 TTS 錯誤：$msg');
      _finish();
    });
    _tts.setProgressHandler((text, start, end, word) => onProgress?.call(end));
    // 最後套用聲音（setLanguage 可能會把聲音換回預設）
    await _applyVoice();
  }

  Completer<void>? _done;

  /// 唸完、被取消或出錯都算結束
  void _finish() {
    _speaking = false;
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// 唸出文字，等到唸完（或出錯、被打斷）才回傳
  Future<void> speak(String text) async {
    final clean = cleanForSpeech(text);
    if (clean.isEmpty) return;
    _finish(); // 結束上一段的等待
    final done = _done = Completer<void>();
    _speaking = true;
    try {
      final r = await _tts.speak(clean);
      if (r == 0) _finish(); // Android 回傳 0 表示沒唸成功
    } catch (e) {
      debugPrint('🔇 TTS 無法播放：$e');
      _finish();
    }
    // 保險：平台沒回報唸完時，依字數估一個最長時間，時間到就當作唸完
    final limit = Duration(seconds: 8 + (clean.length / 3).ceil());
    await done.future.timeout(limit, onTimeout: () {
      debugPrint('🔇 TTS 沒有回報唸完，逾時自動結束');
      _finish();
    });
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } finally {
      _finish();
    }
  }

  /// Markdown 清理（移除符號，保留純文字供 TTS 朗讀）
  String cleanForSpeech(String text) {
    var result = text;

    // ✅ Dart 用 replaceAllMapped 才能取得捕獲群組
    // 粗體 / 斜體 / 粗斜體：***x*** **x** *x*
    result = result.replaceAllMapped(
      RegExp(r'\*{1,3}(.+?)\*{1,3}'),
          (m) => m.group(1) ?? '',
    );

    // 底線粗體 / 斜體：__x__ _x_
    result = result.replaceAllMapped(
      RegExp(r'_{1,2}(.+?)_{1,2}'),
          (m) => m.group(1) ?? '',
    );

    // 標題：## 標題
    result = result.replaceAll(RegExp(r'#{1,6}\s*'), '');

    // 程式碼區塊與行內程式碼
    result = result.replaceAll(RegExp(r'```[\s\S]*?```'), '程式碼略');
    result = result.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
          (m) => m.group(1) ?? '',
    );

    // 連結：[文字](url) → 文字
    result = result.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^\)]+\)'),
          (m) => m.group(1) ?? '',
    );

    // 刪除線：~~x~~
    result = result.replaceAllMapped(
      RegExp(r'~~(.+?)~~'),
          (m) => m.group(1) ?? '',
    );

    // 清單符號：- / * / 1.
    result = result.replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '');
    result = result.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');

    // 多餘換行 → 句號（讓 TTS 自然停頓）
    result = result.replaceAll(RegExp(r'\n{2,}'), '。');
    result = result.replaceAll('\n', '，');

    return result.trim();
  }

  Future<void> dispose() => stop();
}