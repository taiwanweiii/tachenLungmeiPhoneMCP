import 'dart:convert';

import 'package:curtain_mcp_flutter/core/config/app_config.dart';
import 'package:curtain_mcp_flutter/models/mcp_models.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_draft_flow.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_transport.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/services/mcp_client_service.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假的網頁容器：記錄 App 對網頁橋接的呼叫
class FakeTransport implements CabinetTransport {
  final calls = <(String, List<dynamic>)>[];
  bool session = true;
  final Map<String, Map<String, dynamic>> replies = {};

  @override
  Future<Map<String, dynamic>> call(String method, List<dynamic> args) async {
    calls.add((method, args));
    return replies[method] ?? {'ok': true};
  }

  @override
  Future<bool> hasBridge() async => true;
  @override
  Future<bool> hasSession() async => session;
  @override
  Future<Map<String, dynamic>> signIn(String u, String p) async => {'ok': true};
  @override
  Future<void> reload(Uri uri) async {}
}

/// 假的 MCP：記錄 HTTP 呼叫、回傳固定草稿。
/// [hasTools] = true 模擬新版 MCP（有 get_pending_draft／mark_draft_applied 工具，經 proxy 也能用）；
/// false 模擬舊版（沒有工具，改打 /drafts HTTP 端點）。
class FakeMcp extends McpClientService {
  FakeMcp() : super(Dio(), AppConfig());
  final requests = <(String, String, Object?)>[];
  final toolCalls = <(String, Map<String, dynamic>)>[];
  dynamic draft;
  bool hasTools = false;

  @override
  Future<ToolResult?> callToolAsync(
      String toolName, Map<String, dynamic> args) async {
    if (!hasTools) throw Exception('找不到工具「$toolName」，可能所屬的 MCP Server 已關閉');
    toolCalls.add((toolName, args));
    if (toolName == 'get_pending_draft') {
      if (draft == null) {
        return ToolResult(isError: true, content: [
          ToolContent(type: 'text', text: '找不到案件 ${args['caseNo']} 的待套用草稿')
        ]);
      }
      return ToolResult(
          content: [ToolContent(type: 'text', text: jsonEncode(draft))]);
    }
    return ToolResult(
        content: [ToolContent(type: 'text', text: '{"removed":1}')]);
  }

  @override
  Future<dynamic> httpJson(String method, String path, {Object? body}) async {
    requests.add((method, path, body));
    if (method == 'GET') {
      if (draft == null) throw Exception('找不到案件的待套用草稿');
      return draft;
    }
    return {'removed': 1};
  }
}

/// 舊版 MCP 經網站 proxy：/drafts 不轉發，拿到的是網頁 HTML（解析 JSON 會失敗）
class _HtmlMcp extends FakeMcp {
  @override
  Future<dynamic> httpJson(String method, String path, {Object? body}) async =>
      jsonDecode('<!doctype html><html></html>');
}

Map<String, dynamic> cab(String id, String status, String pn) => {
      'localId': id,
      'productNo': pn,
      'status': status,
      'params': {'width': 600},
    };

void main() {
  late WebSession session;
  late CabinetWebController ctrl;
  late FakeMcp mcp;
  late FakeTransport tp;
  late CabinetDraftFlow flow;

  const link =
      'https://p3dweb.example.com/app/store-price/261100M/A/1?draft=261100M&space=s1&wall=w1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session = WebSession();
    await session.init();
    ctrl = CabinetWebController(session);
    mcp = FakeMcp();
    tp = FakeTransport()
      ..replies['whenReady'] = {'ok': true}
      ..replies['getState'] = {'ok': true, 'price': 1000, 'cabinets': []}
      ..replies['applyDraft'] = {'ok': true, 'added': []};
    mcp.draft = {
      'spaces': [
        {
          'localId': 's1',
          'walls': [
            {
              'localId': 'w1',
              'cabinets': [
                cab('c1', 'I', 'A01'),
                cab('c2', 'U', 'A02'), // 不是新增，不應套入
                cab('c3', 'I', 'A03'),
              ],
            },
            {
              'localId': 'w2',
              'cabinets': [cab('c9', 'I', 'ZZZ')], // 別面牆，不應套入
            },
          ],
        },
      ],
    };
    flow = CabinetDraftFlow(ctrl, mcp);
  });

  /// 模擬容器建好並載入完成
  Future<void> loadPage() async {
    ctrl.attachTransport(tp);
    await ctrl.onPageLoaded();
    await ctrl.waitUntilReady(timeout: const Duration(seconds: 5));
    // 讓 flow 後續的 applyDraft 跑完
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  test('不是 store-price 草稿連結：不攔截', () {
    expect(flow.handleLink('https://example.com/app/order/store/261100M?newFlow=true&draft=a&space=s1&wall=w1'), false);
    expect(flow.handleLink('https://example.com/app/store-price/261100M/A/1'), false);
    expect(flow.handleLink('not a url %%'), false);
    expect(ctrl.isOpen, false);
  });

  test('攔截連結：開啟該案件、只套入這面牆的新增柜子', () async {
    expect(flow.handleLink(link), true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 視窗開在編輯既有案件的網址上，而且一定帶 embed=1
    expect(ctrl.isOpen, true);
    final q = ctrl.targetUri!.queryParameters;
    expect(q['embed'], '1');
    expect(q['caseNo'], '261100M');
    expect(q['roomId'], 'A');
    expect(q['closetId'], '1');
    expect(mcp.requests.first.$1, 'GET');
    expect(mcp.requests.first.$2, '/drafts/261100M');

    await loadPage();

    final apply = tp.calls.firstWhere((c) => c.$1 == 'applyDraft');
    final payload = apply.$2[0] as Map;
    final applied = (payload['cabinets'] as List).map((c) => (c as Map)['productNo']).toList();
    expect(applied, ['A01', 'A03']); // 沒有 U 的 A02，也沒有別面牆的 ZZZ
    expect((apply.$2[1] as Map)['clear'], false); // 保留案件原有櫃體
    // 在使用者確認之前，絕不能自動更新案件
    expect(tp.calls.any((c) => c.$1 == 'updateCase'), false);
    expect(tp.calls.any((c) => c.$1 == 'submit'), false);
  });

  test('存檔成功後回報 MCP 已套用的柜子；存檔前不回報', () async {
    flow.handleLink(link);
    await loadPage();
    expect(mcp.requests.where((r) => r.$1 == 'POST'), isEmpty);

    ctrl.onBridgeEvent({
      'type': 'saved',
      'data': {'caseNo': '261100M', 'updated': true},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final post = mcp.requests.where((r) => r.$1 == 'POST').toList();
    expect(post.length, 1);
    expect(post.first.$2, '/drafts/261100M/applied');
    expect((post.first.$3 as Map)['cabinets'], ['s1:w1:c1', 's1:w1:c3']);

    // 同一批不會重複回報
    ctrl.onBridgeEvent({'type': 'saved', 'data': {'updated': true}});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mcp.requests.where((r) => r.$1 == 'POST').length, 1);
  });

  test('草稿取不到：顯示錯誤，不套入、不回報', () async {
    mcp.draft = null;
    flow.handleLink(link);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ctrl.error, contains('取得草稿失敗'));
    expect(tp.calls.any((c) => c.$1 == 'applyDraft'), false);
  });

  group('建單後自動存檔（背景頁，不開畫面）', () {
    late CabinetWebController bg;
    late FakeTransport btp;

    setUp(() {
      bg = CabinetWebController(session, background: true);
      btp = FakeTransport()
        ..replies['whenReady'] = {'ok': true}
        ..replies['applyDraft'] = {'ok': true, 'added': []}
        // 算完的狀態：有價格、讀得到規格值
        ..replies['getState'] = {
          'ok': true,
          'price': 7285,
          'cabinets': [
            {
              'uuid': 'u1',
              'productNo': 'A01',
              'props': [
                {'propsName': 'width', 'value': 600, 'type': 'NUMBER'},
              ],
            },
          ],
        }
        ..replies['updateCase'] = {'ok': true, 'price': 7285};
    });

    Future<({bool ok, String message, num? price})?> run() async {
      final f = flow.autoSave(link, bg);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bg.attachTransport(btp);
      await bg.onPageLoaded();
      return f;
    }

    test('套入這面牆的新增柜子後直接更新詢單，回報 MCP，關掉背景頁', () async {
      expect(bg.isOpen, false);
      final r = await run();
      expect(r?.ok, true);
      expect(r?.price, 7285);
      final apply = btp.calls.firstWhere((c) => c.$1 == 'applyDraft');
      final applied = ((apply.$2[0] as Map)['cabinets'] as List)
          .map((c) => (c as Map)['productNo'])
          .toList();
      expect(applied, ['A01', 'A03']);
      expect((apply.$2[1] as Map)['clear'], false);
      // 真的存檔（不是演練）
      final upd = btp.calls.firstWhere((c) => c.$1 == 'updateCase');
      expect((upd.$2[0] as Map)['dryRun'], false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final post = mcp.requests.where((r) => r.$1 == 'POST').toList();
      expect(post.single.$2, '/drafts/261100M/applied');
      expect(bg.isOpen, false); // 用完就關，之後試算會重新開
      // 畫面上的系統櫃視窗完全沒被打開
      expect(ctrl.isOpen, false);
    });

    test('網頁存檔失敗：回報失敗原因、不回報 MCP、一樣關掉背景頁', () async {
      btp.replies['updateCase'] = {'ok': false, 'message': '用料選項需要重新確認'};
      final r = await run();
      expect(r?.ok, false);
      expect(r?.message, contains('用料選項'));
      expect(mcp.requests.where((r) => r.$1 == 'POST'), isEmpty);
      expect(bg.isOpen, false);
    });

    test('新版 MCP：草稿走 MCP 工具（經網站 proxy 也能用），不打 /drafts', () async {
      mcp.hasTools = true;
      final r = await run();
      expect(r?.ok, true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mcp.requests, isEmpty); // 完全沒打 HTTP /drafts
      expect(mcp.toolCalls.first.$1, 'get_pending_draft');
      expect(mcp.toolCalls.first.$2['caseNo'], '261100M');
      final mark = mcp.toolCalls.firstWhere((c) => c.$1 == 'mark_draft_applied');
      expect(mark.$2['cabinets'], ['s1:w1:c1', 's1:w1:c3']);
    });

    test('草稿回來不是 JSON（例如被網頁 HTML 擋下）：顯示看得懂的原因', () async {
      final bad = _HtmlMcp();
      final f2 = CabinetDraftFlow(ctrl, bad);
      final fut = f2.autoSave(link, bg);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bg.attachTransport(btp);
      await bg.onPageLoaded();
      final r = await fut;
      expect(r?.ok, false);
      expect(r?.message, '伺服器回傳的不是草稿資料');
      expect(r?.message, isNot(contains('Exception')));
    });

    test('不是更新詢單連結：不處理', () async {
      final r = await flow.autoSave('https://example.com/app/order/store/X?newFlow=true', bg);
      expect(r, isNull);
      expect(bg.isOpen, false);
    });
  });

  group('建單後直接存（背景頁已經算好，不重新載入）', () {
    late CabinetWebController bg;
    late FakeTransport btp;

    setUp(() async {
      mcp.hasTools = true;
      (((mcp.draft as Map)['spaces'] as List)[0]['walls'] as List)[0]['wallName'] = '牆面1';
      bg = CabinetWebController(session, background: true);
      btp = FakeTransport()
        ..replies['whenReady'] = {'ok': true}
        ..replies['getState'] = {'ok': true, 'price': 7285, 'cabinets': []}
        ..replies['saveToCase'] = {'ok': true, 'price': 7285};
      // 背景頁開著（建單前一直在試算）
      final f = bg.openNew();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bg.attachTransport(btp);
      await bg.onPageLoaded();
      await f;
    });

    test('直接叫背景頁存進新案件（帶案號、空間、牆面、牆名），不重新載入、回報 MCP、關掉背景頁', () async {
      expect(bg.isOpen, true);
      final r = await flow.saveDirect(link, bg);
      expect(r?.ok, true);
      expect(r?.price, 7285);
      final save = btp.calls.singleWhere((c) => c.$1 == 'saveToCase');
      expect(save.$2[0], {
        'caseNo': '261100M',
        'roomId': 'A',
        'closetId': '1',
        'closetName': '牆面1',
        'dryRun': false,
      });
      // 沒有重新載入案件、沒有重新套櫃子、沒有走更新詢單
      expect(btp.calls.where((c) => c.$1 == 'applyDraft' || c.$1 == 'updateCase'), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final mark = mcp.toolCalls.firstWhere((c) => c.$1 == 'mark_draft_applied');
      expect(mark.$2['cabinets'], ['s1:w1:c1', 's1:w1:c3']);
      expect(bg.isOpen, false);
    });

    test('還沒寫資料庫就停了（例如報價還在算）：可以改走重新載入，不回報 MCP', () async {
      btp.replies['saveToCase'] = {'ok': false, 'stage': 'check', 'message': '報價還在計算中'};
      final r = await flow.saveDirect(link, bg);
      expect(r?.ok, false);
      expect(r?.fallback, true);
      expect(mcp.toolCalls.where((c) => c.$1 == 'mark_draft_applied'), isEmpty);
    });

    test('寫到一半失敗：不能自動重存（可能重複），關掉背景頁讓使用者手動開', () async {
      btp.replies['saveToCase'] = {'ok': false, 'stage': 'save', 'message': '儲存櫃組失敗（HTTP 500）'};
      final r = await flow.saveDirect(link, bg);
      expect(r?.ok, false);
      expect(r?.fallback, false);
      expect(r?.message, contains('HTTP 500'));
      expect(bg.isOpen, false);
    });

    test('網頁還沒部署新版（沒有 saveToCase）：改走重新載入', () async {
      btp.replies['saveToCase'] = {'ok': false, 'message': '網頁橋接尚未就緒'};
      final r = await flow.saveDirect(link, bg);
      expect(r?.fallback, true);
    });

    test('取草稿失敗（還沒寫資料庫）：改走重新載入', () async {
      mcp.draft = null;
      final r = await flow.saveDirect(link, bg);
      expect(r?.fallback, true);
      expect(btp.calls.where((c) => c.$1 == 'saveToCase'), isEmpty);
    });

    test('背景頁沒開著：直接改走重新載入', () async {
      bg.close();
      final r = await flow.saveDirect(link, bg);
      expect(r?.fallback, true);
      expect(btp.calls.where((c) => c.$1 == 'saveToCase'), isEmpty);
    });
  });

  test('這面牆沒有新增柜子：顯示錯誤', () async {
    mcp.draft = {
      'spaces': [
        {
          'localId': 's1',
          'walls': [
            {'localId': 'w1', 'cabinets': [cab('c2', 'U', 'A02')]},
          ],
        },
      ],
    };
    flow.handleLink(link);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ctrl.error, contains('沒有要新增'));
  });
}
