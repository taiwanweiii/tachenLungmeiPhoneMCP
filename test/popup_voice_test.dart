import 'package:curtain_mcp_flutter/features/cabinet/cabinet_transport.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/services/chat_orchestrator.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeTransport implements CabinetTransport {
  final calls = <(String, List<dynamic>)>[];
  @override
  Future<Map<String, dynamic>> call(String method, List<dynamic> args) async {
    calls.add((method, args));
    return {'ok': true, 'handled': true, 'applied': ['x']};
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

void main() {
  late CabinetWebController ctrl;
  late FakeTransport tp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final session = WebSession();
    await session.init();
    ctrl = CabinetWebController(session);
    tp = FakeTransport();
  });

  Future<void> loaded() async {
    ctrl.attachTransport(tp);
    await ctrl.onPageLoaded();
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  group('視窗開著時的語音', () {
    test('沒開視窗、或網頁還沒準備好：語音照常送 AI', () async {
      expect(ctrl.acceptsVoice, false);
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ctrl.acceptsVoice, false); // 還沒載完
      ctrl.close();
      await f;
    });

    test('挑選視窗開好之後：語音交給網頁，原文照傳', () async {
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await loaded();
      expect(ctrl.acceptsVoice, true);
      final r = await ctrl.voiceCommand('寬六十 左開 後縮零');
      expect(r['handled'], true);
      final v = tp.calls.where((c) => c.$1 == 'voice').single;
      expect(v.$2.single, '寬六十 左開 後縮零');
      ctrl.close();
      await f;
    });

    test('關掉視窗後：語音回到 AI', () async {
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await loaded();
      ctrl.close();
      await f;
      expect(ctrl.acceptsVoice, false);
    });

    test('修改訂單視窗也一樣會收語音', () async {
      final f = ctrl.editOrder({'customer': 'x', 'roomName': 'y', 'cabinets': []});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await loaded();
      expect(ctrl.acceptsVoice, true);
      ctrl.close();
      await f;
    });
  });

  group('AI 預先選好', () {
    test('挑選頁載好後，把預先選好的內容交給網頁（一次）', () async {
      final pre = {
        'items': [
          {'productNo': 'A01', 'quantity': 2, 'specs': {'width': 600}}
        ],
        'autoAdd': true,
      };
      final f = ctrl.pickProducts(preselect: pre);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await loaded();
      final calls = tp.calls.where((c) => c.$1 == 'preselect').toList();
      expect(calls.length, 1);
      expect((calls.single.$2.single as Map)['autoAdd'], true);
      ctrl.close();
      await f;
    });

    test('沒有預先選好：不呼叫 preselect', () async {
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await loaded();
      expect(tp.calls.any((c) => c.$1 == 'preselect'), false);
      ctrl.close();
      await f;
    });

    test('上一次的預先選好不會留到下一次', () async {
      var f = ctrl.pickProducts(preselect: {
        'candidates': ['A01', 'A01-NF']
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.close();
      await f;
      tp.calls.clear();
      f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await loaded();
      expect(tp.calls.any((c) => c.$1 == 'preselect'), false);
      ctrl.close();
      await f;
    });

    test('AI 的挑選工具參數 → 預先選好內容', () {
      final one = ChatOrchestrator.buildPreselect({
        'productNo': 'A01',
        'quantity': 3,
        'specs': {'width': 600, 'direction': 'L'},
      })!;
      expect((one['items'] as List).single['quantity'], 3);
      expect((one['items'] as List).single['specs'], {'width': 600, 'direction': 'L'});
      expect(one['autoAdd'], false);

      // 小模型把規格放在最外層也接受
      final flat = ChatOrchestrator.buildPreselect({'productNo': 'A02', 'width': 800})!;
      expect((flat['items'] as List).single['specs'], {'width': 800});

      // 數量沒帶 = 1，不會是 0 或負的
      expect(
          (ChatOrchestrator.buildPreselect({'productNo': 'A01', 'quantity': 0})!['items']
                  as List)
              .single['quantity'],
          1);

      // 分不出來：只給候選
      final cands = ChatOrchestrator.buildPreselect({
        'candidates': ['A01', 'A01-NF']
      })!;
      expect(cands['candidates'], ['A01', 'A01-NF']);
      expect(cands.containsKey('items'), false);

      // 什麼都沒帶：完整目錄
      expect(ChatOrchestrator.buildPreselect({}), isNull);
    });

    test('search_products 結果取出品號，截斷或找不到時不過濾', () {
      expect(
          ChatOrchestrator.parseSearchProductNos('找到 2 個柜子：\n'
              '- **A01** 三門衣櫃（衣櫃）\n'
              '- **A01-NF** 三門衣櫃無框\n'),
          ['A01', 'A01-NF']);
      // 超過 20 個只列一部分：不能拿來過濾
      expect(
          ChatOrchestrator.parseSearchProductNos('找到 30 個柜子：\n'
              '- **A01** 衣櫃\n…還有 10 個，請用更精確的關鍵字。\n'),
          isNull);
      expect(ChatOrchestrator.parseSearchProductNos('找不到符合「xx」的柜子。'), isNull);
    });
  });
}
