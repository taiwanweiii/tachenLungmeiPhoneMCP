import 'dart:async';

import 'package:curtain_mcp_flutter/core/config/app_config.dart';
import 'package:curtain_mcp_flutter/services/chat_orchestrator.dart';
import 'package:curtain_mcp_flutter/services/mcp_client_service.dart';
import 'package:curtain_mcp_flutter/services/ollama_service.dart';
import 'package:curtain_mcp_flutter/voice/mobile_voice_output.dart';
import 'package:curtain_mcp_flutter/voice/voice_input.dart';
import 'package:curtain_mcp_flutter/voice/voice_orchestrator.dart';
import 'package:curtain_mcp_flutter/voice/voice_settings.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每次開始聽依序拿一段「劇本」：回傳這次聽到的字（null = 沒聽到）。
/// 劇本回傳 [never] 代表不會自己結束，要被 cancel 才停。
typedef Script = Future<String?> Function(FakeInput input);

class FakeInput implements VoiceInput {
  FakeInput(this.script);
  final List<Script> script;
  final calls = <String>[];
  final options = <ListenOptions>[];
  Completer<String?>? _cur;

  static Future<String?> never(FakeInput _) => Completer<String?>().future;

  @override
  void Function(String text)? onPartial;
  @override
  void Function(double level)? onLevel;
  @override
  bool get isReady => true;
  @override
  String? get lastError => null;
  @override
  Future<void> initialize() async {}

  @override
  Future<void> startRecording({ListenOptions options = const ListenOptions()}) async {
    calls.add('start');
    this.options.add(options);
    final c = _cur = Completer<String?>();
    final s = script.isEmpty ? null : script.removeAt(0);
    if (s == null) {
      c.complete(null);
    } else {
      unawaited(s(this).then((v) {
        if (!c.isCompleted) c.complete(v);
      }));
    }
  }

  @override
  Future<String?> awaitResult() => _cur?.future ?? Future.value(null);

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    final c = _cur;
    if (c != null && !c.isCompleted) c.complete(null);
  }

  @override
  Future<void> armAutoStop(double endSilenceSeconds) async => calls.add('arm');

  @override
  Future<void> stopListening() async => calls.add('stop');
  @override
  Future<String?> stopAndTranscribe() => awaitResult();
  @override
  Future<String?> recordOnce({Duration maxDuration = const Duration(seconds: 15)}) async => null;
  @override
  Future<void> dispose() async {}
}

/// 假的喇叭：唸一段要 [speakTime]，被 stop 就提早結束
class FakeOutput extends MobileVoiceOutput {
  FakeOutput({this.speakTime = const Duration(milliseconds: 600)});
  final Duration speakTime;
  final spoken = <String>[];
  int stops = 0;
  Completer<void>? _c;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    final c = _c = Completer<void>();
    await c.future.timeout(speakTime, onTimeout: () {});
  }

  @override
  Future<void> stop() async {
    stops++;
    final c = _c;
    if (c != null && !c.isCompleted) c.complete();
  }
}

/// 假的 AI：記下收到的話，回固定的回覆
class FakeChat extends ChatOrchestrator {
  FakeChat() : super(OllamaService(Dio(), AppConfig()), McpClientService(Dio(), AppConfig()));
  final asked = <String>[];

  @override
  Future<({String content, List<String> toolsUsed})> sendMessageAsync(
      String userMessage, {bool voice = false, String? aiNote}) async {
    asked.add(userMessage);
    return (content: '好的，這是 $userMessage 的回覆內容', toolsUsed: const <String>[]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeOutput out;
  late FakeChat chat;

  VoiceOrchestrator make(FakeInput input, VoiceConversationSettings s) {
    final v = VoiceOrchestrator(input, out, chat)..settings = s;
    return v;
  }

  setUp(() {
    out = FakeOutput();
    chat = FakeChat();
  });

  test('沒開連續對話：講一句、AI 回一句就停；聽的時候帶設定的秒數', () async {
    final input = FakeInput([(_) async => '我要看訂單']);
    final v = make(input, VoiceConversationSettings(idleSeconds: 12, endSilenceSeconds: 2.0));
    await v.startTurn();
    expect(chat.asked, ['我要看訂單']);
    expect(input.calls.where((c) => c == 'start').length, 1);
    expect(input.options.first.idleSeconds, 12);
    expect(input.options.first.endSilenceSeconds, 2.0);
    expect(out.spoken.length, 1);
  });

  test('連續對話：AI 講完自動再聽；一直沒開口就暫停', () async {
    var paused = false;
    var errors = 0;
    final input = FakeInput([
      (_) async => '第一句',
      (_) async => '第二句',
      (_) async => null, // 沒開口
    ]);
    final v = make(input, VoiceConversationSettings(continuous: true, keywords: const []))
      ..onPaused = () { paused = true; }
      ..onError = (_) { errors++; };
    await v.startTurn();
    expect(chat.asked, ['第一句', '第二句']);
    expect(paused, true);
    expect(errors, 0); // 暫停不是錯誤
  });

  test('插話：AI 講話中說「停一下，改成兩個」→ 打斷 AI，直接把「改成兩個」交給 AI', () async {
    var barged = false;
    final input = FakeInput([
      (_) async => '我要看訂單',
      // AI 第一次講話時邊聽：先收到回音，再聽到使用者插話
      (inp) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        inp.onPartial?.call('好的這是');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        inp.onPartial?.call('好的這是停一下改成兩個');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return '好的這是停一下改成兩個';
      },
      FakeInput.never, // AI 第二次講話時邊聽：沒人插話，唸完會被取消
      (_) async => null, // 之後沒開口 → 暫停
    ]);
    final v = make(input, VoiceConversationSettings(continuous: true, keywords: const ['停一下']))
      ..onBargeIn = () { barged = true; };
    await v.startTurn();

    expect(barged, true);
    expect(chat.asked, ['我要看訂單', '改成兩個']); // 插話後講的話直接送出，不用再聽一次
    expect(input.calls, contains('arm')); // 打斷後接著聽使用者講完
    expect(out.stops, greaterThan(0)); // AI 被打斷
    // AI 講話時的那次聽不會因安靜自動結束
    expect(input.options[1].autoStop, false);
    // 第二次 AI 講完沒人插話：那次聽被取消
    expect(input.calls, contains('cancel'));
  });

  test('AI 講話時只有回音、沒說關鍵字：不打斷，唸完照常繼續聽', () async {
    final input = FakeInput([
      (_) async => '第一句',
      (inp) async {
        inp.onPartial?.call('好的這是第一句的回覆內容');
        return Completer<String?>().future; // 不會自己結束
      },
      (_) async => null,
    ]);
    var barged = false;
    final v = make(input, VoiceConversationSettings(continuous: true, keywords: const ['停一下']))
      ..onBargeIn = () { barged = true; };
    await v.startTurn();
    expect(barged, false);
    expect(chat.asked, ['第一句']);
    expect(out.spoken.length, 1);
  });

  test('結束連續對話：聽到一半按停，不會再自動開始', () async {
    final input = FakeInput([FakeInput.never]);
    var paused = false;
    var errors = 0;
    final v = make(input, VoiceConversationSettings(continuous: true))
      ..onPaused = () { paused = true; }
      ..onError = (_) { errors++; };
    final f = v.startTurn();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await v.stopLoop();
    await f;
    expect(chat.asked, isEmpty);
    expect(paused, false);
    expect(errors, 0);
    expect(v.inLoop, false);
  });
}
