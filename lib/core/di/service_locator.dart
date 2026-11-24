import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';
import '../config/app_config.dart';
import '../../services/mcp_client_service.dart';
import '../../services/ollama_service.dart';
import '../../services/connectivity_service.dart';
import '../../services/chat_orchestrator.dart';
import '../../services/skill_store.dart';          // ← 新增
import '../../services/web_session.dart';
import '../../features/cabinet/cabinet_web_controller.dart';
import '../../features/cabinet/cabinet_draft_flow.dart';
import '../utils/link_launcher.dart';
import '../../voice/voice_input.dart';
import '../../voice/voice_input_factory.dart';
import '../../voice/mobile_voice_output.dart';
import '../../voice/voice_orchestrator.dart';

final GetIt sl = GetIt.instance;

Future<void> setupServiceLocator() async {

  // ── AppConfig ─────────────────────────────────────────
  final config = AppConfig();
  await config.init();
  sl.registerSingleton<AppConfig>(config);

  // ── SkillStore（需要 async init）──────────────────────  ← 新增
  final skillStore = SkillStore();
  await skillStore.init();
  sl.registerSingleton<SkillStore>(skillStore);

  // ── 系統櫃網頁（內嵌 WebView）────────────────────────
  final webSession = WebSession();
  await webSession.init();
  sl.registerSingleton<WebSession>(webSession);
  sl.registerSingleton<CabinetWebController>(CabinetWebController(webSession));
  // 看不見的背景配置頁：算已選櫃子的預設規格值和報價
  sl.registerSingleton<CabinetWebController>(
    CabinetWebController(webSession, background: true),
    instanceName: 'quote',
  );

  // ── Dio instances ─────────────────────────────────────
  sl.registerLazySingleton<Dio>(
        () => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 120),
    )),
    instanceName: 'ollama',
  );
  sl.registerLazySingleton<Dio>(
        () => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    )),
    instanceName: 'mcp',
  );

  // ── Services ──────────────────────────────────────────
  sl.registerLazySingleton(() => OllamaService(
    sl<Dio>(instanceName: 'ollama'),
    sl<AppConfig>(),
  ));

  sl.registerLazySingleton(() => McpClientService(
    sl<Dio>(instanceName: 'mcp'),
    sl<AppConfig>(),
  ));

  sl.registerLazySingleton(() => CabinetDraftFlow(
    sl<CabinetWebController>(),
    sl<McpClientService>(),
  ));
  // 「更新詢單」連結改在 App 內的系統櫃視窗處理
  linkInterceptor = (url) => sl<CabinetDraftFlow>().handleLink(url);

  sl.registerLazySingleton(() => ChatOrchestrator(
    sl<OllamaService>(),
    sl<McpClientService>(),
  ));

  sl.registerLazySingleton(() => ConnectivityService(
    sl<OllamaService>(),
    sl<AppConfig>(),
  ));

  // ── Voice ─────────────────────────────────────────────
  // Web 用瀏覽器 Web Speech API，Android 用原生 SpeechRecognizer
  sl.registerLazySingleton<VoiceInput>(
          () => createVoiceInput(language: 'zh-TW'));
  sl.registerLazySingleton<MobileVoiceOutput>(
          () => MobileVoiceOutput(language: 'zh-TW'));
  sl.registerLazySingleton(() => VoiceOrchestrator(
    sl<VoiceInput>(),
    sl<MobileVoiceOutput>(),
    sl<ChatOrchestrator>(),
  ));
}