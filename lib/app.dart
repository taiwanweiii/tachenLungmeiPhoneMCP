import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:google_fonts/google_fonts.dart';
import 'features/cabinet/cabinet_overlay.dart';
import 'features/cabinet/cabinet_web_controller.dart';
import 'features/splash/splash_page.dart';
import 'features/chat/chat_page.dart';
import 'features/chat/simple_style.dart';
import 'features/settings/settings_page.dart';
import 'features/skills/skill_select_page.dart';   // ← 新增
import 'features/skills/skill_editor_page.dart';   // ← 新增

class CurtainMcpApp extends ConsumerWidget {
  const CurtainMcpApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 畫面風格（設定裡選）換掉整個 App 的配色；傳統＝原本的主題
    return AnimatedBuilder(
      animation: Listenable.merge([AppStyle.style, AppStyle.mode]),
      builder: (context, _) => MaterialApp(
      title: '隆美系統櫃助理',
      debugShowCheckedModeBanner: false,
      theme: AppStyle.theme(baseTheme(Brightness.light)),
      darkTheme: AppStyle.theme(baseTheme(Brightness.dark)),
      themeMode: AppStyle.themeMode,
      // 系統櫃網頁的浮動視窗放在所有頁面之上，切換頁面時不會被關掉
      builder: (context, child) => Stack(
        children: [
          // 背景報價頁放在最底層：網頁正常執行，但被上面不透明的頁面蓋住，使用者看不到
          // （Android 的原生網頁元件不吃 Opacity，只能靠蓋住）
          CabinetBackgroundHost(
              controller:
                  GetIt.instance<CabinetWebController>(instanceName: 'quote')),
          if (child != null) child,
          CabinetOverlay(controller: GetIt.instance<CabinetWebController>()),
        ],
      ),
      initialRoute: '/',
      routes: {
        '/':         (_) => const SplashPage(),
        '/chat':     (_) => const ChatPage(),
        '/settings': (_) => const SettingsPage(),
        '/skills':   (_) => const SkillSelectPage(),   // ← 新增
        '/skill/new': (_) => const SkillEditorPage(),  // ← 新增
      },
    ),
    );
  }
}

/// App 原本的主題（傳統）。其他風格以它為底換顏色和圓角。
ThemeData baseTheme(Brightness b) => b == Brightness.light
    ? ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
        textTheme: GoogleFonts.notoSansTcTextTheme(),
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 56),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      )
    : ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        textTheme:
        GoogleFonts.notoSansTcTextTheme(ThemeData.dark().textTheme),
      );