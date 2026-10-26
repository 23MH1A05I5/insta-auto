import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/automation_provider.dart';
import 'providers/comment_provider.dart';
import 'routes/app_router.dart';

import 'services/app_updater.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final authProvider = AuthProvider();
  try {
    await authProvider.initialize();
  } catch (_) {
    // Session restore failed — splash screen will handle retry
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<AutomationProvider>(create: (_) => AutomationProvider()),
        ChangeNotifierProvider<CommentProvider>(create: (_) => CommentProvider()),
        ChangeNotifierProvider<AppUpdaterService>(create: (_) => AppUpdaterService()),
      ],
      child: const InstaAutoApp(),
    ),
  );
}

class InstaAutoApp extends StatelessWidget {
  const InstaAutoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'InstaAuto',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      routerConfig: appRouter,
    );
  }
}
