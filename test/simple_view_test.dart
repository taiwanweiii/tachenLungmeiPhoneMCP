import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/features/chat/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final g = GetIt.instance;
    await g.reset();
    final s = WebSession();
    await s.init();
    g.registerSingleton<CabinetWebController>(CabinetWebController(s));
  });

  for (final picked in [false, true]) {
    testWidgets('簡易畫面：${picked ? '有' : '沒有'}選好的櫃子時正常顯示', (t) async {
      t.view.physicalSize = const Size(720, 1600);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        // 跟 App 一樣的 FilledButton 主題（最小寬度無限大），曾經因此讓簡易頁整頁畫不出來
        theme: ThemeData(
          useMaterial3: true,
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 56)),
          ),
        ),
        home: Scaffold(
          body: buildSimpleViewForTest(
            picked: picked
                ? const [PickedItem('A01', '單門衣櫃/3抽屜', 1, missing: ['寬度', '開門方向'])]
                : const [],
            messages: const [],
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 500));
      expect(tester_exception(t), isNull);
      expect(find.text('從目錄挑選'), findsOneWidget);
      if (picked) expect(find.text('送出'), findsOneWidget);
    });
  }
}

Object? tester_exception(WidgetTester t) => t.takeException();
