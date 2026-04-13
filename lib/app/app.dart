import 'package:flutter/material.dart';

import '../ui/kit.dart';
import 'routes.dart';

class GlacierApp extends StatelessWidget {
  const GlacierApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Glacier',
      theme: AppTheme.light(),
      initialRoute: AppRoutes.home,
      routes: AppRoutes.routes,
    );
  }
}
