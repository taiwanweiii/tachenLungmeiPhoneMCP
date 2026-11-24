import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PickedItem 網站預設值也要送給 AI', () {
    test('沒動過規格：預設值（例如後縮 0）會出現在規格參數', () {
      const p = PickedItem('A02-ND', '衣櫃/3抽屜', 1,
          defaults: {'width': 800, 'height': 2304, 'marginB': 0});
      expect(p.forAi, contains('marginB=0'));
      expect(p.forAi, contains('width=800'));
    });

    test('使用者動過的規格蓋過預設值', () {
      const p = PickedItem('A02-ND', '衣櫃/3抽屜', 1,
          specs: {'marginB': 10}, defaults: {'marginB': 0, 'width': 800});
      expect(p.forAi, contains('marginB=10'));
      expect(p.forAi, isNot(contains('marginB=0')));
      expect(p.forAi, contains('width=800'));
    });

    test('配置頁核對過的實際值蓋過挑選畫面的預設，使用者動過的最優先', () {
      const p = PickedItem('A02-ND', '衣櫃/3抽屜', 1,
          specs: {'width': 600},
          defaults: {'width': 800, 'marginB': 0},
          actual: {'width': 750, 'marginB': 18});
      expect(p.forAi, contains('width=600'));
      expect(p.forAi, contains('marginB=18'));
    });

    test('改數量、套用實際值之後預設值還在', () {
      const p = PickedItem('A02-ND', '衣櫃/3抽屜', 1, defaults: {'marginB': 0});
      expect(p.withQuantity(2).defaults, {'marginB': 0});
      expect(p.withActual({'width': 800}, '').defaults, {'marginB': 0});
    });

    test('沒有任何規格也沒有預設：不加規格參數', () {
      const p = PickedItem('X', '無規格', 1);
      expect(p.forAi, isNot(contains('規格參數')));
    });
  });
}
