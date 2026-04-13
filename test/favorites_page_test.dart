import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glacier/main.dart';
import 'package:glacier/models/favorite_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('favorites menu hides tag manager when tag feature disabled',
      (WidgetTester tester) async {
    final favorites = [
      FavoriteCollection(
        id: 'fav-1',
        name: '收藏夹一',
        sources: const <String>[],
        layer1: LayerSettings(),
        layer2: LayerSettings(viewMode: ViewMode.list),
      ),
    ];
    SharedPreferences.setMockInitialValues({
      'favorite_collections_v2':
          jsonEncode(favorites.map((e) => e.toJson()).toList()),
      'glacier_settings_tag_enabled': false,
      'glacier_settings_auto_enter_last_favorite': false,
    });

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    expect(find.text('标签管理'), findsNothing);
    expect(find.text('设置'), findsOneWidget);
  });
}
