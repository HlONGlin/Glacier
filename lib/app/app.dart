import 'package:flutter/material.dart';

import '../core/utils/app_settings.dart';
import '../ui/kit.dart';
import 'routes.dart';

class GlacierApp extends StatefulWidget {
  const GlacierApp({super.key});

  @override
  State<GlacierApp> createState() => _GlacierAppState();
}

class _GlacierAppState extends State<GlacierApp> {
  String _themeMode = 'light';

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_loadThemeMode);
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final mode = await AppSettings.getThemeMode();
    if (mounted && mode != _themeMode) setState(() => _themeMode = mode);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_loadThemeMode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppThemeColors.dark = _themeMode == 'dark';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Glacier',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode == 'dark' ? ThemeMode.dark : ThemeMode.light,
      initialRoute: AppRoutes.home,
      routes: AppRoutes.routes,
    );
  }
}
