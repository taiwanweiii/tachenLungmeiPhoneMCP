import 'package:curtain_mcp_flutter/core/config/app_config.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_transport.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/models/mcp_models.dart';
import 'package:curtain_mcp_flutter/services/chat_orchestrator.dart';
import 'package:curtain_mcp_flutter/services/mcp_client_service.dart';
import 'package:curtain_mcp_flutter/services/ollama_service.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeTransport implements CabinetTransport {
  final calls = <(String, List<dynamic>)>[];
  @override
  Future<Map<String, dynamic>> call(String method, List<dynamic> args) async {
    calls.add((method, args));
    return {'ok': true};
  }

  @override
  Future<bool> hasBridge() async => true;
  @override
  Future<bool> hasSession() async => true;
  @override
  Future<Map<String, dynamic>> signIn(String u, String p) async => {'ok': true};
  @override
  Future<void> reload(Uri uri) async {}
}

/// 假的 MCP：記錄 quick_order 的呼叫參數，回傳指定的結果
class FakeMcp extends McpClientService {
  FakeMcp() : super(Dio(), AppConfig());
  final calls = <Map<String, dynamic>>[];
  ToolResult? next;

  @override
  Future<ToolResult?> callToolAsync(
      String toolName, Map<String, dynamic> args) async {
    expect(toolName, 'quick_order');
    calls.add(Map<String, dynamic>.from(args));
    return next;
  }
}

const _order = {
  'customer': '小明',
  'roomName': '主臥',
  'contactPhone': '0912',
  'cabinets': [
    {'productNo': 'A01', 'width': 600, 'direction': 'L', 'marginB': 0},
  ],
};

void main() {
  group('修改訂單視窗（controller）', () {
    late CabinetWebController ctrl;
    late FakeTransport tp;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final session = WebSession();
      await session.init();
      ctrl = CabinetWebController(session);
      tp = FakeTransport();
    });

    test('開修改頁：網址帶 mode=edit，載完頁面後把訂單交給網頁', () async {
      final f = ctrl.editOrder(Map<String, dynamic>.from(_order));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ctrl.targetUri!.path, '/public/mcp-order-edit');
      expect(ctrl.targetUri!.queryParameters['mode'], 'edit');
      expect(ctrl.targetUri!.queryParameters['embed'], '1');
      expect(ctrl.editMode, true);
      expect(ctrl.lightPage, true);

      ctrl.attachTransport(tp);
      await ctrl.onPageLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final load = tp.calls.where((c) => c.$1 == 'loadOrder').toList();
      expect(load.length, 1);
      expect((load.first.$2[0] as Map)['customer'], '小明');
      // 公開頁不用登入
      expect(tp.calls.any((c) => c.$1 == 'signIn'), false);
      ctrl.close();
      await f;
    });

    test('套用修改：回傳改好的訂單並關閉視窗', () async {
      final f = ctrl.editOrder(Map<String, dynamic>.from(_order));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.onBridgeEvent({
        'type': 'orderEdited',
        'data': {
          'order': {
            'customer': '小明',
            'roomName': '主臥',
            'cabinets': [
              {'productNo': 'A01', 'width': 450, 'direction': 'R', 'marginB': 10},
            ],
          },
        },
      });
      final edited = await f;
      expect(edited, isNotNull);
      expect((edited!['cabinets'] as List).single['width'], 450);
      expect(ctrl.isOpen, false);
      expect(ctrl.editMode, false);
    });

    test('關掉視窗：視為不改（回傳 null）', () async {
      final f = ctrl.editOrder(Map<String, dynamic>.from(_order));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.close();
      expect(await f, isNull);
    });

    test('修改頁按縮小：不縮成小視窗', () async {
      final f = ctrl.editOrder(Map<String, dynamic>.from(_order));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.minimize();
      expect(ctrl.mode == CabinetPanelMode.mini, false);
      ctrl.close();
      await f;
    });
  });

  group('重新產生訂單摘要（orchestrator）', () {
    late FakeMcp mcp;
    late ChatOrchestrator chat;

    setUp(() {
      mcp = FakeMcp();
      chat = ChatOrchestrator(OllamaService(Dio(), AppConfig()), mcp);
    });

    ToolResult summary() => ToolResult(content: [
          ToolContent(
              type: 'text',
              text: '**新訂單摘要**\n- 客戶：小明\n- 柜子：1. A01 寬 450',
              audience: const ['user']),
        ]);

    test('摘要正常：變成新的待確認訂單；絕不帶 confirmed', () async {
      mcp.next = summary();
      final edited = {
        ..._order,
        'confirmed': true, // 就算有人帶了也要被拿掉
        'cabinets': [
          {'productNo': 'A01', 'width': 450}
        ],
      };
      final r = await chat.reviewEditedOrder(edited);
      expect(r.pending, true);
      expect(r.content, contains('新訂單摘要'));
      expect(mcp.calls.single.containsKey('confirmed'), false);
      expect(chat.hasPendingOrder, true);
      expect(chat.lastReplyPendingOrder, true);
      expect((chat.pendingOrderArgs!['cabinets'] as List).single['width'], 450);
    });

    test('缺規格：不是待確認狀態，回傳工具的說明', () async {
      mcp.next = ToolResult(content: [
        ToolContent(type: 'text', text: '柜子規格需要補齊：缺少 direction'),
      ]);
      final r = await chat.reviewEditedOrder({..._order});
      expect(r.pending, false);
      expect(r.content, contains('缺少'));
      expect(chat.hasPendingOrder, false);
    });

    test('工具失敗：顯示失敗訊息，不是待確認', () async {
      mcp.next = ToolResult(isError: true, content: [
        ToolContent(type: 'text', text: '客戶姓名不能空白'),
      ]);
      final r = await chat.reviewEditedOrder({..._order});
      expect(r.pending, false);
      expect(r.content, startsWith('⚠️'));
      expect(chat.hasPendingOrder, false);
    });

    test('pendingOrderArgs 回傳的是複本，外面改不到內部狀態', () async {
      mcp.next = summary();
      await chat.reviewEditedOrder({..._order});
      final a = chat.pendingOrderArgs!;
      a['customer'] = '被改掉';
      expect(chat.pendingOrderArgs!['customer'], '小明');
    });
  });
}
