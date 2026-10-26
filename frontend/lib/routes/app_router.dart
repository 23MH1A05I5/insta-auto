import 'package:go_router/go_router.dart';
import '../models/instagram_media.dart';
import '../screens/auth/splash_screen.dart';
import '../screens/auth/login_screen.dart'; // also exports RegisterScreen
import '../screens/auth/connect_instagram_screen.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/automation/select_post_screen.dart';
import '../screens/automation/trigger_config_screen.dart';
import '../screens/automation/replies_config_screen.dart';
import '../screens/automation/dm_config_screen.dart';
import '../screens/automation/preview_automation_screen.dart';
import '../screens/automation/automations_list_screen.dart';
import '../screens/activity/activity_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../models/automation_model.dart';
import '../screens/automation/backfill_comments_screen.dart';
import '../screens/reels/reel_details_screen.dart';
import '../screens/reels/reel_comments_screen.dart';
import '../screens/reels/all_reels_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/register',
      builder: (context, state) => const RegisterScreen(),
    ),
    GoRoute(
      path: '/connect-instagram',
      builder: (context, state) => const ConnectInstagramScreen(),
    ),
    GoRoute(
      path: '/dashboard',
      builder: (context, state) => const DashboardScreen(),
    ),
    GoRoute(
      path: '/automation/select-post',
      builder: (context, state) => const SelectPostScreen(),
    ),
    GoRoute(
      path: '/automation/configure-trigger',
      builder: (context, state) => const TriggerConfigScreen(),
    ),
    GoRoute(
      path: '/automation/configure-replies',
      builder: (context, state) => const RepliesConfigScreen(),
    ),
    GoRoute(
      path: '/automation/configure-dm',
      builder: (context, state) => const DmConfigScreen(),
    ),
    GoRoute(
      path: '/automation/preview',
      builder: (context, state) => const PreviewAutomationScreen(),
    ),
    GoRoute(
      path: '/automations',
      builder: (context, state) => const AutomationsListScreen(),
    ),
    GoRoute(
      path: '/activity',
      builder: (context, state) => const ActivityScreen(),
    ),
    GoRoute(
      path: '/profile',
      builder: (context, state) => const ProfileScreen(),
    ),
    GoRoute(
      path: '/reels',
      builder: (context, state) => const AllReelsScreen(),
    ),
    GoRoute(
      path: '/posts',
      builder: (context, state) => const AllReelsScreen(),
    ),
    // ── Reels ──────────────────────────────────────────────────────────────────
    GoRoute(
      path: '/reels/:mediaId',
      builder: (context, state) {
        final media = state.extra as InstagramMedia?;
        // If no media passed via extra, build a minimal placeholder from mediaId
        final m = media ?? InstagramMedia(
          id        : state.pathParameters['mediaId']!,
          mediaType : 'IMAGE',
        );
        return ReelDetailsScreen(media: m);
      },
    ),
    GoRoute(
      path: '/reels/:mediaId/comments',
      builder: (context, state) {
        final mediaId = state.pathParameters['mediaId']!;
        final media   = state.extra as InstagramMedia?;
        return ReelCommentsScreen(mediaId: mediaId, media: media);
      },
    ),
    GoRoute(
      path: '/reels/:mediaId/backfill',
      builder: (context, state) {
        final mediaId = state.pathParameters['mediaId']!;
        final extra = state.extra as Map<String, dynamic>?;
        final media = extra?['media'] as InstagramMedia?;
        final automation = extra?['automation'] as Automation?;
        return BackfillCommentsScreen(
          mediaId: mediaId,
          media: media,
          automation: automation,
        );
      },
    ),
  ],
);
