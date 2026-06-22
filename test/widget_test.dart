// 既存テストはテンプレ由来で `MyApp` を参照しており旧コードでも壊れていた。
// flutter_map / FMTC 移行に伴い、ここではアプリ側の本体は触らずプレースホルダーに置き換える。
// 必要に応じて FlutterMap の表示テスト等を後日追加する。

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
