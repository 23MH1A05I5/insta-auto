import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/common/common_widgets.dart';
import '../../widgets/common/app_bottom_nav_bar.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  String _filter = 'all'; // all | sent | failed | skipped | pending | processing | unknown
  String _actionTypeFilter = 'all'; // all | dm | public_reply
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
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
    _searchCtrl.dispose();
    super.dispose();
  }

  void _showDetailSheet(ActivityEntry initialEntry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Consumer<AutomationProvider>(
        builder: (context, provider, _) {
          // Find the latest version of this entry from the provider
          final entry = provider.activity.firstWhere(
            (e) => (e.id != null && e.id == initialEntry.id) || (e.commentId == initialEntry.commentId),
            orElse: () => initialEntry,
          );

          final isRetrying = provider.retryingActivityId == (entry.id ?? entry.commentId);
          final dmNeedsRetry = !entry.privateReplySent && (entry.privateReplyStatus == 'failed' || entry.privateReplyStatus == 'error');
          final isReconcileRequired = entry.reconciliationRequired == true || entry.status == 'reconciliation_required';
          final isUnknown = entry.status == 'unknown';

          return Container(
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
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(sheetContext)),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 10),
                _detailRow('User', '@${entry.username ?? "unknown"}'),
                _detailRow(
                  'Status',
                  entry.status.toUpperCase(),
                  valueColor: (entry.status == 'success' || entry.status == 'sent')
                      ? AppColors.success
                      : (entry.status == 'skipped'
                          ? AppColors.warning
                          : (entry.status == 'unknown'
                              ? Colors.orange
                              : (entry.status == 'reconciliation_required'
                                  ? Colors.purple
                                  : (entry.status == 'processing'
                                      ? AppColors.primary
                                      : (entry.status == 'pending'
                                          ? AppColors.textSecondary
                                          : AppColors.error))))),
                ),
                if (entry.text != null) _detailRow('Comment Text', '"${entry.text}"'),
                if (entry.ruleMatched != null) _detailRow('Rule Matched', entry.ruleMatched!),
                _detailRow(
                  'Public Reply',
                  entry.publicReplySent
                      ? (entry.publicReplyMessage?.isNotEmpty == true ? entry.publicReplyMessage! : 'Reply sent')
                      : (entry.publicReplyStatus == 'failed'
                          ? 'Failed: ${entry.publicReplyError ?? "Could not send"}'
                          : (entry.publicReplyStatus == 'disabled' ? 'Disabled' : 'Not sent (${entry.publicReplyStatus ?? "skipped"})')),
                  valueColor: entry.publicReplySent
                      ? AppColors.success
                      : (entry.publicReplyStatus == 'failed' ? AppColors.error : AppColors.textSecondary),
                ),
                _detailRow(
                  'Private DM',
                  entry.privateReplySent
                      ? (entry.privateReplyMessage?.isNotEmpty == true ? entry.privateReplyMessage! : 'DM delivered')
                      : (entry.privateReplyStatus == 'failed'
                          ? 'Failed: ${entry.privateReplyError ?? "Could not deliver"}'
                          : (entry.privateReplyStatus == 'disabled' ? 'Disabled' : 'Not sent (${entry.privateReplyStatus ?? "skipped"})')),
                  valueColor: entry.privateReplySent
                      ? AppColors.success
                      : (entry.privateReplyStatus == 'failed' ? AppColors.error : AppColors.textSecondary),
                ),
                if (entry.attempts > 0) _detailRow('Delivery Attempts', '${entry.attempts}'),
                if (entry.skipReason != null)
                  _detailRow('Skip Reason', entry.skipReason!, valueColor: AppColors.warning),
                if (isReconcileRequired)
                  _detailRow('Reconciliation', 'Required: Prior delivery outcome is ambiguous', valueColor: Colors.purple),
                if (entry.error != null)
                  _detailRow('Error Log', entry.error!, valueColor: AppColors.error),
                if (entry.createdAt != null)
                  _detailRow('Timestamp', DateFormat('MMM d, yyyy • h:mm a').format(entry.createdAt!)),

                const SizedBox(height: 16),

                // Reconciliation info banner if required
                if (isReconcileRequired) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.purple.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.purple.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.sync_problem_outlined, size: 20, color: Colors.purple),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Reconciliation Required: Prior delivery outcome is ambiguous. Cannot retry until verified.',
                            style: TextStyle(fontSize: 12, color: Colors.purple, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ] else if (isUnknown) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.help_outline, size: 20, color: Colors.orange),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Delivery status is uncertain. Verification required before retrying.',
                            style: TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                // Retry DM Action Section
                if (dmNeedsRetry && !isReconcileRequired) ...[
                  if (entry.retryEligible) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: ElevatedButton.icon(
                        onPressed: isRetrying
                            ? null
                            : () async {
                                final activityKey = entry.id ?? entry.commentId ?? '';
                                final messenger = ScaffoldMessenger.of(context);
                                final res = await provider.retryDm(activityKey);
                                if (res['ok'] == true) {
                                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text('✅ DM delivered successfully!'),
                                      backgroundColor: AppColors.success,
                                    ),
                                  );
                                } else {
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text('❌ Retry failed: ${res['error'] ?? 'Unknown error'}'),
                                      backgroundColor: AppColors.error,
                                    ),
                                  );
                                }
                              },
                        icon: isRetrying
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.refresh, size: 20),
                        label: Text(
                          isRetrying ? 'Retrying DM...' : 'Retry DM',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ] else ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 20, color: AppColors.warning),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              entry.retryReason ?? 'This DM cannot be retried per Meta policies.',
                              style: const TextStyle(fontSize: 12, color: AppColors.warning, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 10),
              ],
            ),
          );
        },
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
    final activity = provider.activity;

    final filtered = activity.where((e) {
      final st = e.status.toLowerCase();
      if (_filter == 'sent' && !(st == 'sent' || st == 'success')) return false;
      if (_filter == 'failed' && !(st == 'failed' || st == 'error')) return false;
      if (_filter == 'skipped' && st != 'skipped') return false;
      if (_filter == 'pending' && st != 'pending') return false;
      if (_filter == 'processing' && st != 'processing') return false;
      if (_filter == 'unknown' && !(st == 'unknown' || st == 'reconciliation_required')) return false;

      if (_actionTypeFilter == 'dm') {
        if (!e.privateReplySent && e.privateReplyStatus == null && (e.privateReplyMessage == null || e.privateReplyMessage!.isEmpty)) {
          return false;
        }
      } else if (_actionTypeFilter == 'public_reply') {
        if (!e.publicReplySent && e.publicReplyStatus == null && (e.publicReplyMessage == null || e.publicReplyMessage!.isEmpty)) {
          return false;
        }
      }

      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchUser = (e.username ?? '').toLowerCase().contains(q);
        final matchText = (e.text ?? '').toLowerCase().contains(q);
        final matchAuto = (e.automationName ?? '').toLowerCase().contains(q);
        final matchComment = (e.commentId ?? '').toLowerCase().contains(q);
        if (!matchUser && !matchText && !matchAuto && !matchComment) return false;
      }

      return true;
    }).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Activity History'),
        leading: context.canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios),
                onPressed: () => context.pop(),
              )
            : null,
        actions: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
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
            // Search Bar
            TextField(
              controller: _searchCtrl,
              onChanged: (val) => setState(() => _searchQuery = val.trim()),
              decoration: InputDecoration(
                hintText: 'Search by username, comment, or rule...',
                prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.textSecondary),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
                fillColor: AppColors.surface,
                filled: true,
              ),
            ),
            const SizedBox(height: 14),

            // Status Filter Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _chip('all', 'All Statuses (${activity.length})'),
                  const SizedBox(width: 8),
                  _chip('sent', 'Confirmed Sent'),
                  const SizedBox(width: 8),
                  _chip('failed', 'Failed (${activity.where((e) => e.status == 'failed' || e.status == 'error').length})'),
                  const SizedBox(width: 8),
                  _chip('skipped', 'Skipped (${activity.where((e) => e.status == 'skipped').length})'),
                  const SizedBox(width: 8),
                  _chip('pending', 'Pending'),
                  const SizedBox(width: 8),
                  _chip('processing', 'Processing'),
                  const SizedBox(width: 8),
                  _chip('unknown', 'Unknown'),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Action Type Filter Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _typeChip('all', 'All Actions'),
                  const SizedBox(width: 8),
                  _typeChip('public_reply', 'Public Replies'),
                  const SizedBox(width: 8),
                  _typeChip('dm', 'Private DMs'),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // If has failed entries or in failed filter, show the Resend Failed Actions banner
            if ((_filter == 'failed' || _filter == 'all') && activity.any((e) => (e.status == 'failed' || e.status == 'error') && e.retryEligible)) ...[
              _buildFailedHeaderBanner(context, provider, filtered),
              const SizedBox(height: 14),
            ],

            // Activity list
            if (provider.loadingActivity && activity.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (filtered.isEmpty)
              EmptyState(
                icon: _filter == 'failed' ? Icons.check_circle_outline : Icons.history_outlined,
                title: _filter == 'failed' ? 'No failed actions' : 'No activity found',
                subtitle: _filter == 'failed'
                    ? 'All automated replies and direct messages have been delivered successfully.'
                    : 'Activity logs will appear here when comments arrive on your Instagram posts.',
              )
            else
              ...filtered.map((entry) {
                final isRetryingThis = provider.retryingActivityId == (entry.id ?? entry.commentId);
                return _ActivityCard(
                  entry: entry,
                  isRetrying: isRetryingThis,
                  onTap: () => _showDetailSheet(entry),
                  onResend: ((entry.status == 'error' || entry.status == 'failed') && entry.retryEligible)
                      ? () => _handleRetrySingle(context, provider, entry)
                      : null,
                );
              }),

            const SizedBox(height: 40),
          ],
        ),
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 3),
    );
  }

  Widget _buildFailedHeaderBanner(
    BuildContext context,
    AutomationProvider provider,
    List<ActivityEntry> failedEntries,
  ) {
    final eligibleCount = failedEntries.where((e) => e.retryEligible).length;
    final isResending = provider.resendingAll;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: AppColors.error.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.sync_problem_rounded, color: AppColors.error, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${failedEntries.length} Failed Action${failedEntries.length == 1 ? "" : "s"}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                        if (eligibleCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$eligibleCount eligible',
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.success),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      eligibleCount > 0
                          ? 'Resend direct messages that failed delivery within 7 days.'
                          : 'No failed actions are currently eligible for retry per Meta rules.',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (failedEntries.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: ElevatedButton.icon(
                onPressed: (isResending || eligibleCount == 0)
                    ? null
                    : () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final res = await provider.resendAllFailed();
                        if (res['ok'] == true) {
                          final msg = res['message'] ?? 'Resent failed actions!';
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('✅ $msg'),
                              backgroundColor: AppColors.success,
                            ),
                          );
                        } else {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('❌ ${res['error'] ?? 'Bulk resend failed'}'),
                              backgroundColor: AppColors.error,
                            ),
                          );
                        }
                      },
                icon: isResending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(
                  isResending
                      ? 'Resending Failed Actions...'
                      : (eligibleCount > 0 ? 'Resend Failed Actions ($eligibleCount)' : 'No Eligible Actions to Resend'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.textSecondary.withValues(alpha: 0.15),
                  disabledForegroundColor: AppColors.textSecondary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleRetrySingle(
    BuildContext context,
    AutomationProvider provider,
    ActivityEntry entry,
  ) async {
    final activityKey = entry.id ?? entry.commentId ?? '';
    final messenger = ScaffoldMessenger.of(context);
    final res = await provider.retryDm(activityKey);
    if (res['ok'] == true) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('✅ DM delivered successfully!'),
          backgroundColor: AppColors.success,
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('❌ Retry failed: ${res['error'] ?? 'Unknown error'}'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Widget _chip(String key, String label) {
    final selected = _filter == key;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      selected: selected,
      selectedColor: AppColors.primary.withValues(alpha: 0.15),
      labelStyle: TextStyle(color: selected ? AppColors.primary : AppColors.textSecondary),
      side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
      onSelected: (_) => setState(() => _filter = key),
    );
  }

  Widget _typeChip(String key, String label) {
    final selected = _actionTypeFilter == key;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      selected: selected,
      selectedColor: AppColors.secondary.withValues(alpha: 0.15),
      labelStyle: TextStyle(color: selected ? AppColors.secondary : AppColors.textSecondary),
      side: BorderSide(color: selected ? AppColors.secondary : AppColors.border),
      onSelected: (_) => setState(() => _actionTypeFilter = key),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  final ActivityEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onResend;
  final bool isRetrying;

  const _ActivityCard({
    required this.entry,
    required this.onTap,
    this.onResend,
    this.isRetrying = false,
  });

  @override
  Widget build(BuildContext context) {
    Color statusColor;
    IconData statusIcon;

    switch (entry.status.toLowerCase()) {
      case 'sent':
      case 'success':
        statusColor = AppColors.success;
        statusIcon  = Icons.check_circle_outline;
        break;
      case 'skipped':
        statusColor = AppColors.warning;
        statusIcon  = Icons.skip_next_outlined;
        break;
      case 'unknown':
        statusColor = Colors.orange;
        statusIcon  = Icons.help_outline;
        break;
      case 'reconciliation_required':
        statusColor = Colors.purple;
        statusIcon  = Icons.sync_problem_outlined;
        break;
      case 'processing':
        statusColor = AppColors.primary;
        statusIcon  = Icons.hourglass_top_outlined;
        break;
      case 'pending':
        statusColor = AppColors.textSecondary;
        statusIcon  = Icons.pending_outlined;
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
            color: statusColor.withValues(alpha: 0.12),
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
            if (entry.status == 'error' && (entry.privateReplyError != null || entry.error != null || entry.publicReplyError != null)) ...[
              const SizedBox(height: 3),
              Text(
                entry.privateReplyError ?? entry.error ?? entry.publicReplyError ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.error, fontWeight: FontWeight.w500),
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
                        color: AppColors.primary.withValues(alpha: 0.08),
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
                if ((entry.status == 'error' || entry.status == 'failed') && entry.retryEligible) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                    ),
                    child: const Text(
                      'RETRY ELIGIBLE',
                      style: TextStyle(fontSize: 9, color: AppColors.primary, fontWeight: FontWeight.w700),
                    ),
                  ),
                ] else if (entry.status == 'reconciliation_required' || entry.reconciliationRequired == true) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.purple.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'RECONCILIATION REQUIRED',
                      style: TextStyle(fontSize: 9, color: Colors.purple, fontWeight: FontWeight.w700),
                    ),
                  ),
                ] else if (entry.status == 'unknown') ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'UNKNOWN STATUS',
                      style: TextStyle(fontSize: 9, color: Colors.orange, fontWeight: FontWeight.w700),
                    ),
                  ),
                ] else if (entry.status == 'error' || entry.status == 'failed') ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'CANNOT RETRY',
                      style: TextStyle(fontSize: 9, color: AppColors.warning, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: onResend != null
            ? OutlinedButton.icon(
                onPressed: isRetrying ? null : onResend,
                icon: isRetrying
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 14),
                label: Text(
                  isRetrying ? 'Resending' : 'Resend',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(0, 32),
                ),
              )
            : const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
      ),
    );
  }
}
