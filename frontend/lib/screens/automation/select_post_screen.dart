import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/automation/automation_widgets.dart';
import '../../widgets/common/common_widgets.dart';

class SelectPostScreen extends StatefulWidget {
  const SelectPostScreen({super.key});
  @override
  State<SelectPostScreen> createState() => _SelectPostScreenState();
}

class _SelectPostScreenState extends State<SelectPostScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<AutomationProvider>();
      p.fetchMedia(reset: true);
      p.fetchAutomations(silent: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AutomationProvider>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Choose a Post'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/dashboard');
            }
          },
        ),
        actions: [
          Center(child: Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
            child: const Text('Step 1 of 5', style: TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600)),
          )),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Choose where to start', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('Select the post or Reel you want to automate replies for. Posts with existing automations are hidden.',
                    style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                const SizedBox(height: 12),

                // Pill showing count of hidden automated posts
                if (provider.automatedMediaIds.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.panelGray,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.filter_list_rounded, size: 16, color: AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${provider.automatedMediaIds.length} already automated post${provider.automatedMediaIds.length == 1 ? "" : "s"} hidden',
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Selected post preview
                if (provider.selectedMedia != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                    ),
                    child: const Row(children: [
                      Icon(Icons.check_circle, color: AppColors.primary, size: 18),
                      SizedBox(width: 8),
                      Expanded(child: Text('1 post selected — tap another to change',
                          style: TextStyle(fontSize: 13, color: AppColors.primary, fontWeight: FontWeight.w500))),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),

          // Media grid
          Expanded(
            child: _buildContent(provider),
          ),

          // Bottom bar
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/dashboard');
                      }
                    },
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: GradientButton(
                    label: 'Continue',
                    icon: Icons.arrow_forward,
                    onPressed: provider.selectedMedia != null
                        ? () => context.push('/automation/configure-trigger')
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(AutomationProvider provider) {
    if (provider.loadingMedia && provider.media.isEmpty) {
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
        itemCount: 9,
        itemBuilder: (_, __) => const ShimmerCard(height: 120),
      );
    }
    if (provider.mediaError != null && provider.media.isEmpty) {
      return EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load posts',
        subtitle: provider.mediaError ?? 'Check that your Instagram account is connected and has media access.',
        actionLabel: 'Retry',
        onAction: () => provider.fetchMedia(reset: true),
      );
    }
    if (provider.media.isEmpty) {
      return const EmptyState(
        icon: Icons.image_outlined,
        title: 'No posts found',
        subtitle: 'Your Instagram account does not have any media posts yet.',
      );
    }

    final available = provider.availableMedia;
    if (available.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'All posts already automated',
        subtitle: 'You already have an automation configured for every post on your account. Manage them in your Automations list.',
        actionLabel: 'View Automations',
        onAction: () => context.go('/automations'),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollEndNotification && n.metrics.extentAfter < 200) {
          provider.fetchMedia();
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
        itemCount: available.length + (provider.loadingMedia ? 3 : 0),
        itemBuilder: (_, i) {
          if (i >= available.length) return const ShimmerCard(height: 120);
          final m = available[i];
          return InstagramPostCard(
            media: m,
            isSelected: provider.selectedMedia?.id == m.id,
            onTap: () => provider.selectMedia(m),
          );
        },
      ),
    );
  }
}
