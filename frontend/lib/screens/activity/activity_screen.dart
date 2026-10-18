import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/common/common_widgets.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  String _filter = 'all'; // all | success | skipped | error
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<AutomationProvider>();
      p.fetchActivity(reset: true);
      p.fetchAnalytics();
    });

    // Auto-refresh every 4 seconds silently so stats & log update in real-time
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) {
        final p = context.read<AutomationProvider>();
        p.fetchActivity(reset: true, silent: true);
        p.fetchAnalytics();
      }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  void _showDetailSheet(ActivityEntry entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Activity Detail', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const Divider(),
            const SizedBox(height: 10),
            _detailRow('User', '@${entry.username ?? "unknown"}'),
            _detailRow('Status', entry.status.toUpperCase(),
                valueColor: entry.status == 'success'
                    ? AppColors.success
                    : (entry.status == 'skipped' ? AppColors.warning : AppColors.error)),
            if (entry.text != null) _detailRow('Comment Text', '"${entry.text}"'),
            if (entry.ruleMatched != null) _detailRow('Rule Matched', entry.ruleMatched!),
            if (entry.publicReply != null) _detailRow('Public Reply Sent', entry.publicReply!),
            if (entry.privateReply != null) _detailRow('Private DM Sent', entry.privateReply!),
            if (entry.error != null) _detailRow('Error Log', entry.error!, valueColor: AppColors.error),
            if (entry.createdAt != null)
              _detailRow('Timestamp', DateFormat('MMM d, yyyy • h:mm a').format(entry.createdAt!)),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: valueColor ?? AppColors.textPrimary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AutomationProvider>();
    final analytics = provider.analytics;
    final activity = provider.activity;

    final filtered = _filter == 'all'
        ? activity
        : activity.where((e) => e.status.toLowerCase() == _filter).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Activity & Analytics'),
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
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.success.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.success.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    'LIVE',
                    style: TextStyle(
                      color: AppColors.success,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => Future.wait([
              provider.fetchActivity(reset: true),
              provider.fetchAnalytics(),
            ]),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            provider.fetchActivity(reset: true),
            provider.fetchAnalytics(),
          ]);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Top Analytics Stats
            if (analytics != null) ...[
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.25,
                children: [
                  StatCard(
                    label: 'Total Comments',
                    value: '${analytics.commentsReceived}',
                    icon: Icons.chat_bubble_outline,
                    color: AppColors.info,
                  ),
                  StatCard(
                    label: 'Replies Posted',
                    value: '${analytics.repliesSent}',
                    icon: Icons.reply,
                    color: AppColors.success,
                  ),
                  StatCard(
                    label: 'DMs Delivered',
                    value: '${analytics.dmsSent}',
                    icon: Icons.send_outlined,
                    color: AppColors.warning,
                  ),
                  StatCard(
                    label: 'Failed Actions',
                    value: '${analytics.failed}',
                    icon: Icons.error_outline,
                    color: AppColors.error,
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            // Filter Chips (Horizontally Scrollable)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _chip('all', 'All Activity'),
                  const SizedBox(width: 8),
                  _chip('success', 'Success'),
                  const SizedBox(width: 8),
                  _chip('skipped', 'Skipped'),
                  const SizedBox(width: 8),
                  _chip('error', 'Errors'),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Activity list
            if (provider.loadingActivity && activity.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (filtered.isEmpty)
              const EmptyState(
                icon: Icons.history_outlined,
                title: 'No activity found',
                subtitle: 'Activity logs will appear here when comments arrive on your Instagram posts.',
              )
            else
              ...filtered.map((entry) => _ActivityCard(
                    entry: entry,
                    onTap: () => _showDetailSheet(entry),
                  )),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _chip(String key, String label) {
    final selected = _filter == key;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      selected: selected,
      selectedColor: AppColors.primary.withOpacity(0.15),
      labelStyle: TextStyle(color: selected ? AppColors.primary : AppColors.textSecondary),
      side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
      onSelected: (_) => setState(() => _filter = key),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  final ActivityEntry entry;
  final VoidCallback onTap;

  const _ActivityCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    Color statusColor;
    IconData statusIcon;

    switch (entry.status) {
      case 'success':
        statusColor = AppColors.success;
        statusIcon  = Icons.check_circle_outline;
        break;
      case 'skipped':
        statusColor = AppColors.warning;
        statusIcon  = Icons.skip_next_outlined;
        break;
      default:
        statusColor = AppColors.error;
        statusIcon  = Icons.error_outline;
    }

    final timeAgo = entry.createdAt != null
        ? DateFormat('h:mm a').format(entry.createdAt!)
        : 'Just now';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(statusIcon, color: statusColor, size: 20),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '@${entry.username ?? "user"}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timeAgo,
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.text != null) ...[
              const SizedBox(height: 3),
              Text(
                '"${entry.text}"',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                if (entry.ruleMatched != null)
                  Flexible(
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        entry.ruleMatched!,
                        style: const TextStyle(fontSize: 10, color: AppColors.primary, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ),
                if (entry.publicReply != null)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.reply, size: 14, color: AppColors.success),
                  ),
                if (entry.privateReply != null)
                  const Icon(Icons.send_outlined, size: 14, color: AppColors.warning),
              ],
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
      ),
    );
  }
}
