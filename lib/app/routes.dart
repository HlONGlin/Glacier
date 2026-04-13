import '../pages.dart';

class AppRoutes {
  AppRoutes._();

  static const String home = '/';

  static final routes = {
    home: (_) => const FavoritesPage(),
  };
}
