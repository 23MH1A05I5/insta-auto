import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fadeAnim;
  late Animation<double> _scaleAnim;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _fadeAnim  = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _scaleAnim = Tween<double>(begin: 0.7, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _ctrl.forward();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (mounted) setState(() => _hasError = false);
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    try {
      final auth = context.read<AuthProvider>();
      // Only re-initialize if status is still unknown (first launch)
      if (auth.status == AuthStatus.unknown) {
        await auth.initialize();
      }
      if (!mounted) return;

      final status = auth.status;
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;

      if (status == AuthStatus.authenticated) {
        context.go('/dashboard');
      } else {
        context.go('/login');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.heroGradient),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 96, height: 96,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 24, offset: const Offset(0, 8))],
                    ),
                    child: const Icon(Icons.auto_awesome, size: 52, color: AppColors.primary),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'InstaAuto',
                    style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -1),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Instagram Automation, Simplified',
                    style: TextStyle(fontSize: 15, color: Colors.white.withOpacity(0.8), fontWeight: FontWeight.w400),
                  ),
                  const SizedBox(height: 60),
                  if (_hasError) ...[
                    Text(
                      'Connection failed',
                      style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.9)),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _bootstrap,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => context.go('/login'),
                      child: Text('Go to Login', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
                    ),
                  ] else
                    SizedBox(
                      width: 36, height: 36,
                      child: CircularProgressIndicator(color: Colors.white.withOpacity(0.7), strokeWidth: 2.5),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
