import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/features/cabinet/layout_message.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> cab(String no, String title,
        {String? wall, num? along, Map<String, dynamic>? pose, Object? props}) =>
    {
      'productNo': no,
      'title': title,
      'width': 800,
      'height': 2304,
      'depth': 600,
      if (wall != null) 'wall': wall,
      if (along != null) 'along': along,
      if (pose != null) 'pose': pose,
      if (props != null) 'props': props,
    };

void main() {
  group('使用者看到的訊息 composeLayoutMessage', () {
    test('全部都在後牆（語音預設）：只有 1、2、3，不提牆面也沒有座標', () {
      final t = composeLayoutMessage({
        'orderInfo': {'Customer': '阿名'},
        'price': 27666,
        'cabinets': [
          // 故意亂序：網頁給的 along 小的排前面
          cab('A02-ND', '衣櫃/3抽屜', wall: 'back', along: 2550),
          cab('F06', '轉角桌L', wall: 'back', along: 1450),
        ],
      });
      expect(t, contains('客戶：阿名'));
      expect(t, contains('櫃子（由左到右）：'));
      expect(t.indexOf('1. F06'), greaterThan(-1));
      expect(t.indexOf('2. A02-ND'), greaterThan(t.indexOf('1. F06')));
      expect(t, contains('目前報價：27666'));
      expect(t, isNot(contains('牆')), reason: '全在後牆時不提牆面');
      expect(t, isNot(contains('x=')), reason: '座標不能讓使用者看到');
      expect(t, isNot(contains('規格參數')), reason: '規格參數只給 AI');
    });

    test('有櫃子在別面牆：依牆面分組，每面牆各自從 1 開始', () {
      final t = composeLayoutMessage({
        'cabinets': [
          cab('B01', '右牆櫃', wall: 'right', along: 100),
          cab('F06', '轉角桌L', wall: 'back', along: 1450),
          cab('A02', '衣櫃', wall: 'back', along: 2550),
          cab('C01', '左牆櫃', wall: 'left', along: 900),
          cab('C02', '左牆櫃2', wall: 'left', along: 200),
        ],
      });
      // 牆面順序（順時針）：後牆 → 右牆 → 左牆
      final back = t.indexOf('後牆：');
      final left = t.indexOf('左牆：');
      final right = t.indexOf('右牆：');
      expect(back, greaterThan(-1));
      expect(right, greaterThan(back));
      expect(left, greaterThan(right));
      // 左牆順時針是由前往後：along 大（離後牆遠）的排第一
      expect(t.indexOf('1. C01'), greaterThan(left));
      expect(t.indexOf('2. C02'), greaterThan(t.indexOf('1. C01')));
      // 每面牆各自從 1 開始
      expect(t.indexOf('1. B01'), greaterThan(right));
      expect(t, isNot(contains('x=')));
    });

    test('前牆、不靠牆也要列出', () {
      final t = composeLayoutMessage({
        'cabinets': [
          cab('F1', '前牆櫃', wall: 'front', along: 500),
          cab('M1', '中間島', wall: 'none', along: 1000),
          cab('B1', '後牆櫃', wall: 'back', along: 0),
        ],
      });
      expect(t, contains('前牆：'));
      expect(t, contains('未靠牆：'));
      expect(t.indexOf('後牆：'), lessThan(t.indexOf('前牆：')));
      expect(t.indexOf('前牆：'), lessThan(t.indexOf('未靠牆：')));
    });

    test('前牆順時針是由右到左：along 大的排第一', () {
      final t = composeLayoutMessage({
        'cabinets': [
          cab('F1', '前牆左', wall: 'front', along: 100),
          cab('F2', '前牆右', wall: 'front', along: 2000),
        ],
      });
      expect(t.indexOf('1. F2'), greaterThan(-1));
      expect(t.indexOf('2. F1'), greaterThan(t.indexOf('1. F2')));
    });

    test('沒有位置資料（網頁沒給牆面）：維持網頁給的順序、不編造牆面', () {
      final t = composeLayoutMessage({
        'cabinets': [cab('X1', '甲'), cab('X2', '乙')],
      });
      expect(t.indexOf('1. X1'), greaterThan(-1));
      expect(t.indexOf('2. X2'), greaterThan(t.indexOf('1. X1')));
      expect(t, isNot(contains('牆')));
    });

    test('沒有櫃子：明說沒有', () {
      expect(composeLayoutMessage({'cabinets': []}), contains('沒有櫃子'));
    });
  });

  group('只給 AI 的備註 composeLayoutAiNote', () {
    final data = <String, dynamic>{
      'room': {'width': 4000, 'depth': 3000, 'height': 2700},
      'cabinets': [
        cab('A02-ND', '衣櫃/3抽屜',
            wall: 'back',
            along: 2550,
            pose: {'x': 2950, 'z': 300, 'rotationDeg': 0},
            props: [
              {'key': 'width', 'label': '寬度', 'value': 800},
              {'key': 'marginB', 'label': '上固格', 'value': 0},
            ]),
        cab('B01', '右牆櫃',
            wall: 'right', along: 100, pose: {'x': 3700, 'z': 400, 'rotationDeg': 270}),
      ],
    };

    test('有牆面、第幾個、沿牆位置、座標、規格參數', () {
      final n = composeLayoutAiNote(data);
      expect(n, contains('只給你看'));
      expect(n, contains('房間：寬 4000 × 深 3000 × 高 2700'));
      expect(n, contains('後牆第1個'));
      expect(n, contains('沿牆位置 2550'));
      expect(n, contains('座標 x=2950, z=300, 旋轉=0'));
      expect(n, contains('marginB=0'));
      expect(n, contains('右牆第1個'));
    });

    test('尺寸每顆只列一次（props 裡的 width 不重複）', () {
      final n = composeLayoutAiNote(data);
      final line = n.split('\n').firstWhere((l) => l.startsWith('- A02-ND'));
      expect('width=800'.allMatches(line).length, 1);
    });

    test('沒有櫃子就沒有備註', () {
      expect(composeLayoutAiNote({'cabinets': []}), '');
    });
  });

  group('CabinetWebController 發送到聊天', () {
    late CabinetWebController ctrl;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final session = WebSession();
      await session.init();
      ctrl = CabinetWebController(session);
    });

    test('sendToChat 事件：把內容交給聊天頁並收起視窗', () async {
      Map<String, dynamic>? got;
      ctrl.onSendToChat = (d) => got = d;
      await ctrl.openNew();
      expect(ctrl.isOpen, true);

      ctrl.onBridgeEvent({
        'type': 'sendToChat',
        'data': {
          'orderInfo': {'Customer': '阿名'},
          'cabinets': [
            {'productNo': 'F06'},
          ],
        },
      });

      expect(got, isNotNull);
      expect((got!['orderInfo'] as Map)['Customer'], '阿名');
      expect(ctrl.isOpen, false, reason: '發送後視窗要收起來，使用者才看得到聊天');
    });

    test('沒設回呼也不會當掉', () async {
      await ctrl.openNew();
      ctrl.onBridgeEvent({'type': 'sendToChat', 'data': {}});
      expect(ctrl.isOpen, false);
    });
  });
}
