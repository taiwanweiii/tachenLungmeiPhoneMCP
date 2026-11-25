import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/features/chat/chat_page.dart';
import 'package:curtain_mcp_flutter/features/chat/conversation_settings_sheet.dart';
import 'package:curtain_mcp_flutter/features/chat/simple_style.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:curtain_mcp_flutter/voice/voice_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 跟 App 一樣的 FilledButton 主題（最小寬度無限大），曾經讓簡易頁整頁畫不出來
ThemeData _appTheme() => ThemeData(
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 56)),
      ),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final g = GetIt.instance;
    await g.reset();
    final s = WebSession();
    await s.init();
    g.registerSingleton<CabinetWebController>(CabinetWebController(s));
  });

  Future<void> show(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(780, 1688); // 390 x 844
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: _appTheme(), home: Scaffold(body: child)));
    // 動畫會一直跑，不能 pumpAndSettle
    await t.pump(const Duration(milliseconds: 300));
  }

  const phases = {
    '待命': (rec: false, load: false, speak: false),
    '聆聽': (rec: true, load: false, speak: false),
    '思考': (rec: false, load: true, speak: false),
    '回答': (rec: false, load: false, speak: true),
  };

  for (final style in SimpleStyle.values) {
    for (final e in phases.entries) {
      testWidgets('風格 ${style.name}・${e.key}：手機畫面畫得出來', (t) async {
        await show(
          t,
          buildSimpleViewForTest(
            style: style,
            picked: const [PickedItem('A01', '單門衣櫃/3抽屜', 1)],
            messages: const [],
            isRecording: e.value.rec,
            isLoading: e.value.load,
            isSpeaking: e.value.speak,
            continuous: true,
          ),
        );
        expect(t.takeException(), isNull);
        if (style == SimpleStyle.classic) {
          // 傳統：原本的版面（「從目錄挑選」那一排、最下面的「聊天模式」）
          expect(find.text('從目錄挑選'), findsOneWidget);
          expect(find.text('聊天模式'), findsOneWidget);
        } else {
          // 新版面：最下面那一排拿掉了，改成底部的目錄／麥克風／打字
          expect(find.text('聊天模式'), findsNothing);
          expect(find.text(SimpleDock.labelOf(switch (e.key) {
            '聆聽' => MicPhase.listening,
            '思考' => MicPhase.thinking,
            '回答' => MicPhase.speaking,
            _ => MicPhase.idle,
          })), findsOneWidget);
        }
      });
    }
  }

  testWidgets('新版面：點麥克風、長按麥克風、目錄、打字都會觸發', (t) async {
    var taps = 0, longs = 0, picks = 0, keyboards = 0;
    await show(
      t,
      buildSimpleViewForTest(
        style: SimpleStyle.neon,
        picked: const [],
        messages: const [],
        onMicTap: () => taps++,
        onMicLongPress: () => longs++,
        onPick: () => picks++,
        onBackToChat: () => keyboards++,
      ),
    );
    // 麥克風本體（不是下面那行說明文字）
    final mic = find.byWidgetPredicate((w) =>
        w is Semantics && w.properties.label == SimpleDock.labelOf(MicPhase.idle));
    await t.tap(mic);
    await t.pump(const Duration(milliseconds: 100));
    await t.longPress(mic);
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.text('目錄'));
    await t.tap(find.text('打字'));
    await t.pump(const Duration(milliseconds: 100));
    expect((taps, longs, picks, keyboards), (1, 1, 1, 1));
  });

  testWidgets('設定裡選風格：五個選項（含傳統），點了會回報', (t) async {
    SimpleStyle? picked;
    await show(
      t,
      ConversationSettingsSheet(
        initial: VoiceConversationSettings(),
        onChanged: (_) {},
        initialStyle: SimpleStyle.classic,
        onStyleChanged: (s) => picked = s,
      ),
    );
    expect(t.takeException(), isNull);
    for (final name in ['傳統', '霓虹光環', '聲波膠囊', '全息光球', '科幻 HUD']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    await t.tap(find.text('全息光球'));
    await t.pump();
    expect(picked, SimpleStyle.orb);
  });

  test('風格存在手機上；沒選過是傳統', () async {
    expect(await SimpleStyleSpec.load(), SimpleStyle.classic);
    await SimpleStyleSpec.save(SimpleStyle.hud);
    expect(await SimpleStyleSpec.load(), SimpleStyle.hud);
  });
}
