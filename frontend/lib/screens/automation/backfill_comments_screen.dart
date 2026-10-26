import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../models/backfill_model.dart';
import '../../models/instagram_media.dart';
import '../../providers/automation_provider.dart';
import '../../services/api_service.dart';

class BackfillCommentsScreen extends StatefulWidget {
  final String mediaId;
  final InstagramMedia? media;
  final Automation? automation;

  const BackfillCommentsScreen({
    super.key,
    required this.mediaId,
    this.media,
    this.automation,
  });

  @override
  State<BackfillCommentsScreen> createState() => _BackfillCommentsScreenState();
}

class _BackfillCommentsScreenState extends State<BackfillCommentsScreen> {
  final ApiService _api = ApiService();

  Automation? _selectedAutomation;
  InstagramMedia? _media;

  bool _loadingInitial = true;
  bool _loadingPreview = false;
  String? _errorMessage;

  BackfillPreviewResponse? _preview;
  final Set<String> _selectedCommentIds = {};

  BackfillJobModel? _activeJob;
  Timer? _pollTimer;
  bool _isStartingJob = false;
  bool _isRetryingJob = false;
  bool _isResumingJob = false;
  bool _isActivating = false;

  @override
  void initState() {
    super.initState();
    _media = widget.media;
    _selectedAutomation = widget.automation;
    _initScreen();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _initScreen() async {
    final autoP = context.read<AutomationProvider>();

    // Load automations if not loaded
    if (autoP.automations.isEmpty) {
      await autoP.fetchAutomations();
    }

    // Try finding automation for this media if not pre-provided
    if (_selectedAutomation == null) {
      _selectedAutomation = autoP.getAutomationForMedia(widget.mediaId);
      if (_selectedAutomation == null && autoP.automations.isNotEmpty) {
        _selectedAutomation = autoP.automations.first;
      }
    } else {
      final match = autoP.automations.where((a) => a.id == _selectedAutomation!.id);
      if (match.isNotEmpty) {
        _selectedAutomation = match.first;
      }
    }

    // Check if there is an active or recent backfill job for this automation
    if (_selectedAutomation != null) {
      await _checkLatestJob();
    }

    if (mounted) {
      setState(() => _loadingInitial = false);
    }
  }

  Future<void> _checkLatestJob() async {
    if (_selectedAutomation == null) return;
    try {
      final res = await _api.getLatestBackfillJob(_selectedAutomation!.id);
      if (res['job'] != null) {
        final job = BackfillJobModel.fromJson(Map<String, dynamic>.from(res['job'] as Map));
        // If it belongs to this media
        if (job.mediaId == widget.mediaId) {
          setState(() => _activeJob = job);
          if (job.isProcessing) {
            _startPolling(job.id);
          }
        }
      }
    } catch (_) {
      // Ignored - will let user preview
    }
  }

  void _startPolling(String jobId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final res = await _api.getBackfillJob(jobId);
        if (res['job'] != null && mounted) {
          final updated = BackfillJobModel.fromJson(Map<String, dynamic>.from(res['job'] as Map));
          setState(() => _activeJob = updated);
          if (!updated.isProcessing) {
            timer.cancel();
            if (mounted) {
              // Refresh activity and automations in background
              context.read<AutomationProvider>().fetchAutomations();
              context.read<AutomationProvider>().fetchAnalytics();
            }
          }
        }
      } catch (e) {
        debugPrint('⚠️ Error polling backfill job: $e');
      }
    });
  }

  Future<void> _activateAutomation() async {
    if (_selectedAutomation == null) return;
    setState(() {
      _isActivating = true;
      _errorMessage = null;
    });

    try {
      final autoP = context.read<AutomationProvider>();
      final ok = await autoP.updateStatus(_selectedAutomation!.id, 'active');
      if (ok) {
        await autoP.fetchAutomations(silent: true);
        final updated = autoP.automations.firstWhere(
          (a) => a.id == _selectedAutomation!.id,
          orElse: () => _selectedAutomation!,
        );
        setState(() {
          _selectedAutomation = updated;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: AppColors.success,
              content: Text('Automation activated successfully!'),
            ),
          );
        }

        // Auto load preview after activation if not already loaded
        if (_preview == null && _activeJob == null) {
          await _loadPreview();
        }
      } else {
        setState(() => _errorMessage = 'Failed to activate automation rule.');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Error activating automation: $e');
    } finally {
      if (mounted) {
        setState(() => _isActivating = false);
      }
    }
  }

  Future<void> _loadPreview() async {
    if (_selectedAutomation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an automation rule first.')),
      );
      return;
    }

    if (_selectedAutomation!.status != 'active') {
      setState(() {
        _errorMessage = 'Automation is inactive. Activate automation to process existing comments.';
      });
      return;
    }

    setState(() {
      _loadingPreview = true;
      _errorMessage = null;
    });

    try {
      final res = await _api.previewBackfill(
        _selectedAutomation!.id,
        mediaId: widget.mediaId,
      );

      final preview = BackfillPreviewResponse.fromJson(res);
      setState(() {
        _preview = preview;
        _selectedCommentIds.clear();
        // Select all eligible comments by default
        for (final c in preview.comments) {
          if (c.isEligible || c.status == 'eligible') {
            _selectedCommentIds.add(c.commentId);
          }
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to fetch comments for preview: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _loadingPreview = false);
      }
    }
  }

  Future<void> _confirmAndStartJob() async {
    if (_selectedAutomation == null) return;
    if (_selectedAutomation!.status != 'active') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.warning,
          content: Text('Activate automation to process existing comments.'),
        ),
      );
      return;
    }
    if (_selectedCommentIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one eligible comment to process.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.bolt_rounded, color: AppColors.primary, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Confirm Backfill',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Process ${_selectedCommentIds.length} historical comments with automation "${_selectedAutomation!.name.isNotEmpty ? _selectedAutomation!.name : 'Active Rule'}"?',
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.panelGray,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 16, color: AppColors.primary),
                      SizedBox(width: 8),
                      Text(
                        'Anti-Spam & Deduplication Guard',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                  SizedBox(height: 6),
                  Text(
                    '• Never duplicates previously sent public replies or DMs.\n• Paced with human delays to respect Meta policies.\n• Comments >7 days old skip DMs safely.',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Start Processing'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _startJob();
    }
  }

  Future<void> _startJob() async {
    setState(() {
      _isStartingJob = true;
      _errorMessage = null;
    });

    try {
      final res = await _api.startBackfill(
        _selectedAutomation!.id,
        mediaId: widget.mediaId,
        selectedCommentIds: _selectedCommentIds.toList(),
      );

      if (res['job'] != null) {
        final job = BackfillJobModel.fromJson(Map<String, dynamic>.from(res['job'] as Map));
        setState(() {
          _activeJob = job;
        });
        _startPolling(job.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: AppColors.success,
              content: Text('Backfill job started! Processing comments in background...'),
            ),
          );
        }
      }
    } catch (e) {
      setState(() => _errorMessage = 'Failed to start backfill job: $e');
    } finally {
      if (mounted) {
        setState(() => _isStartingJob = false);
      }
    }
  }

  Future<void> _resumeJob() async {
    if (_activeJob == null) return;
    setState(() {
      _isResumingJob = true;
      _errorMessage = null;
    });

    try {
      final res = await _api.resumeBackfillJob(_activeJob!.id);
      if (res['job'] != null) {
        final job = BackfillJobModel.fromJson(Map<String, dynamic>.from(res['job'] as Map));
        setState(() => _activeJob = job);
        _startPolling(job.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: AppColors.success,
              content: Text('Backfill job resumed! Processing remaining comments...'),
            ),
          );
        }
      } else if (res['error'] != null) {
        setState(() => _errorMessage = res['error']);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Failed to resume backfill job: $e');
    } finally {
      if (mounted) {
        setState(() => _isResumingJob = false);
      }
    }
  }

  Future<void> _retryFailedActions() async {
    if (_activeJob == null) return;
    setState(() {
      _isRetryingJob = true;
      _errorMessage = null;
    });

    try {
      final res = await _api.retryBackfillJob(_activeJob!.id);
      if (res['job'] != null) {
        final updated = BackfillJobModel.fromJson(Map<String, dynamic>.from(res['job'] as Map));
        setState(() => _activeJob = updated);
        final successful = res['successCount'] ?? res['successfulRetries'] ?? 0;
        final failed = res['failedCount'] ?? res['failedRetries'] ?? 0;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: successful > 0 ? AppColors.success : AppColors.warning,
              content: Text('Retry complete: $successful sent, $failed failed.'),
            ),
          );
        }
      } else if (res['error'] != null) {
        setState(() => _errorMessage = res['error']);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Retry failed: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: AppColors.error, content: Text('Retry failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isRetryingJob = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Process Existing Comments'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => context.pop(),
        ),
        actions: [
          if (_activeJob != null && !_activeJob!.isProcessing)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Preview again',
              onPressed: () {
                setState(() => _activeJob = null);
                _loadPreview();
              },
            ),
        ],
      ),
      body: _loadingInitial
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Post & Media Info Card
                  _buildMediaCard(),
                  const SizedBox(height: 16),

                  // 2. Automation Rule Selector
                  _buildAutomationSelectorCard(),
                  const SizedBox(height: 16),

                  // Error Banner
                  if (_errorMessage != null) ...[
                    _buildErrorBanner(),
                    const SizedBox(height: 16),
                  ],

                  // 3. Active Job View OR Preview & Selection View
                  if (_activeJob != null) ...[
                    _buildJobStatusView(),
                  ] else ...[
                    _buildPreviewSection(),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  // ── Media Info Card ────────────────────────────────────────────────────────
  Widget _buildMediaCard() {
    final media = _media;
    final thumb = media?.thumbnailUrl ?? media?.mediaUrl;
    final caption = media?.caption;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 64,
              height: 64,
              child: thumb != null && thumb.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: thumb,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.panelGray),
                      errorWidget: (_, __, ___) => Container(
                        color: AppColors.panelGray,
                        child: const Icon(Icons.movie_creation_outlined, color: AppColors.textHint),
                      ),
                    )
                  : Container(
                      color: AppColors.panelGray,
                      child: const Icon(Icons.movie_creation_outlined, color: AppColors.textHint),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        (media?.mediaType ?? 'POST').toUpperCase(),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.chat_bubble_outline_rounded, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      '${media?.commentsCount ?? 0} comments',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  caption != null && caption.isNotEmpty
                      ? caption
                      : 'Instagram Post / Reel (#${widget.mediaId})',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Automation Selector Card ───────────────────────────────────────────────
  Widget _buildAutomationSelectorCard() {
    final autoP = context.watch<AutomationProvider>();
    final automations = autoP.automations;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune_rounded, size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              const Text(
                'Automation Rule',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const Spacer(),
              if (_selectedAutomation != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _selectedAutomation!.status == 'active'
                        ? AppColors.success.withValues(alpha: 0.12)
                        : AppColors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _selectedAutomation!.status.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _selectedAutomation!.status == 'active' ? AppColors.success : AppColors.warning,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (automations.isEmpty)
            const Text(
              'No automations configured. Please create an automation rule first.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: automations.any((a) => a.id == _selectedAutomation?.id)
                  ? _selectedAutomation?.id
                  : (automations.isNotEmpty ? automations.first.id : null),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
                filled: true,
                fillColor: AppColors.inputBg,
              ),
              isExpanded: true,
              items: automations.map((a) {
                final label = a.name.isNotEmpty ? a.name : 'Automation for ${a.mediaId}';
                return DropdownMenuItem<String>(
                  value: a.id,
                  child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                );
              }).toList(),
              onChanged: _activeJob?.isProcessing == true
                  ? null
                  : (val) {
                      if (val == null) return;
                      final selected = automations.firstWhere((a) => a.id == val);
                      setState(() {
                        _selectedAutomation = selected;
                        _preview = null;
                        _selectedCommentIds.clear();
                      });
                      _checkLatestJob();
                    },
            ),

          if (_selectedAutomation != null) ...[
            if (_selectedAutomation!.status != 'active') ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.warning),
                        SizedBox(width: 8),
                        Text(
                          'Automation is Inactive',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Activate automation to process existing comments.',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.3),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _isActivating ? null : _activateAutomation,
                          icon: _isActivating
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.flash_on_rounded, size: 16),
                          label: Text(_isActivating ? 'Activating...' : 'Activate Automation', style: const TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            await context.push('/automations');
                            if (mounted) {
                              await context.read<AutomationProvider>().fetchAutomations(silent: true);
                              _initScreen();
                            }
                          },
                          icon: const Icon(Icons.settings_outlined, size: 16),
                          label: const Text('Automation Settings', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.panelGray,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Trigger: ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
                      Text(
                        _selectedAutomation!.trigger.matchType == 'any'
                            ? 'Any comment'
                            : 'Keywords: ${_selectedAutomation!.trigger.keywords.join(", ")}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        _selectedAutomation!.publicReply.enabled ? Icons.check_circle_outline : Icons.highlight_off,
                        size: 14,
                        color: _selectedAutomation!.publicReply.enabled ? AppColors.success : AppColors.textHint,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Public Reply: ${_selectedAutomation!.publicReply.enabled ? "Active" : "Disabled"}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      const SizedBox(width: 14),
                      Icon(
                        _selectedAutomation!.openingDm.enabled ? Icons.check_circle_outline : Icons.highlight_off,
                        size: 14,
                        color: _selectedAutomation!.openingDm.enabled ? AppColors.success : AppColors.textHint,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'DM: ${_selectedAutomation!.openingDm.enabled ? "Active" : "Disabled"}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Error Banner ───────────────────────────────────────────────────────────
  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorMessage ?? '',
              style: const TextStyle(fontSize: 13, color: AppColors.error, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  // ── Preview Section ────────────────────────────────────────────────────────
  Widget _buildPreviewSection() {
    if (_preview == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.search_rounded, size: 36, color: AppColors.primary),
            ),
            const SizedBox(height: 16),
            const Text(
              'Analyze Existing Comments',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'InstaAuto will fetch all historical comments on this post, match them against your automation rule, and let you preview and select which ones to process.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _loadingPreview ? null : _loadPreview,
              icon: _loadingPreview
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.preview_rounded, size: 20),
              label: Text(_loadingPreview ? 'Fetching Comments...' : 'Preview Comments'),
            ),
          ],
        ),
      );
    }

    final p = _preview!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Breakdown Cards
        const Text(
          'Analysis Summary',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _buildMetricTile('Found', '${p.totalComments}', AppColors.info, Icons.forum_rounded)),
            const SizedBox(width: 8),
            Expanded(child: _buildMetricTile('Eligible', '${p.eligibleCount}', AppColors.success, Icons.check_circle_rounded)),
            const SizedBox(width: 8),
            Expanded(child: _buildMetricTile('Already Sent', '${p.alreadyProcessedCount}', AppColors.warning, Icons.history_rounded)),
            const SizedBox(width: 8),
            Expanded(child: _buildMetricTile('Unmatched', '${p.unmatchedCount}', AppColors.textHint, Icons.remove_circle_outline)),
          ],
        ),
        if (p.expiredDmCount > 0) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${p.expiredDmCount} comment(s) are older than 7 days. Per Meta policy, private DMs are blocked, but public replies will be sent.',
                    style: const TextStyle(fontSize: 11, color: Colors.brown, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 18),

        // Comments List Header with Select All
        Row(
          children: [
            Text(
              'Comments (${p.comments.length})',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            const Spacer(),
            if (p.eligibleCount > 0)
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () {
                  setState(() {
                    final eligibleList = p.comments.where((c) => c.isEligible || c.status == 'eligible').toList();
                    if (_selectedCommentIds.length == eligibleList.length) {
                      _selectedCommentIds.clear();
                    } else {
                      _selectedCommentIds.clear();
                      for (final c in eligibleList) {
                        _selectedCommentIds.add(c.commentId);
                      }
                    }
                  });
                },
                icon: Icon(
                  _selectedCommentIds.isNotEmpty && _selectedCommentIds.length == p.comments.where((c) => c.isEligible || c.status == 'eligible').length
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
                label: Text(
                  _selectedCommentIds.isNotEmpty && _selectedCommentIds.length == p.comments.where((c) => c.isEligible || c.status == 'eligible').length
                      ? 'Deselect All'
                      : 'Select All Eligible (${p.eligibleCount})',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Comments List
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: p.comments.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final comment = p.comments[index];
            return _buildPreviewCommentCard(comment);
          },
        ),
      ],
    );
  }

  Widget _buildMetricTile(String label, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCommentCard(BackfillPreviewComment comment) {
    final isSelected = _selectedCommentIds.contains(comment.commentId);

    Color statusColor;
    String statusLabel;
    if (comment.status == 'eligible') {
      statusColor = AppColors.success;
      statusLabel = 'Eligible';
    } else if (comment.status == 'expired_dm_eligible_public_reply') {
      statusColor = Colors.amber;
      statusLabel = 'Public Reply Only (>7d)';
    } else if (comment.status == 'already_processed') {
      statusColor = AppColors.warning;
      statusLabel = 'Already Processed';
    } else if (comment.status == 'self_comment') {
      statusColor = AppColors.textHint;
      statusLabel = 'Own Comment';
    } else {
      statusColor = AppColors.textHint;
      statusLabel = 'Unmatched';
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: comment.isEligible
          ? () {
              setState(() {
                if (isSelected) {
                  _selectedCommentIds.remove(comment.commentId);
                } else {
                  _selectedCommentIds.add(comment.commentId);
                }
              });
            }
          : null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.primary.withValues(alpha: 0.6) : AppColors.border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          if (comment.isEligible)
            Checkbox(
              value: isSelected,
              activeColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              onChanged: (val) {
                setState(() {
                  if (val == true) {
                    _selectedCommentIds.add(comment.commentId);
                  } else {
                    _selectedCommentIds.remove(comment.commentId);
                  }
                });
              },
            )
          else
            const Padding(
              padding: EdgeInsets.all(12),
              child: Icon(Icons.block_rounded, size: 16, color: AppColors.textHint),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '@${comment.username}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  comment.text,
                  style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                if (comment.isEligible)
                  Row(
                    children: [
                      if (comment.willSendPublicReply) ...[
                        const Icon(Icons.reply_rounded, size: 12, color: AppColors.primary),
                        const SizedBox(width: 4),
                        const Text('Public Reply', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        const SizedBox(width: 10),
                      ],
                      if (comment.willSendDm) ...[
                        const Icon(Icons.send_rounded, size: 12, color: AppColors.info),
                        const SizedBox(width: 4),
                        const Text('Private DM', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ],
                  )
                else if (comment.reason != null)
                  Text(
                    comment.reason!,
                    style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: AppColors.textHint),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

  // ── Active Job Processing View ─────────────────────────────────────────────
  Widget _buildJobStatusView() {
    final job = _activeJob!;

    Color statusColor;
    String statusText;
    if (job.status == 'completed') {
      statusColor = AppColors.success;
      statusText = 'Completed Successfully';
    } else if (job.status == 'completed_with_errors') {
      statusColor = AppColors.warning;
      statusText = 'Completed With Errors';
    } else if (job.status == 'failed') {
      statusColor = AppColors.error;
      statusText = 'Job Failed';
    } else if (job.status == 'paused') {
      statusColor = AppColors.warning;
      statusText = 'Job Paused';
    } else {
      statusColor = AppColors.primary;
      statusText = 'Processing Comments...';
    }

    final pendingCount = (job.totalComments - job.processedCount).clamp(0, job.totalComments);
    final pubSent = job.actions.where((a) => a.publicReplyStatus == 'sent').length;
    final dmSent = job.actions.where((a) => a.dmStatus == 'sent').length;
    final failedActionsCount = job.actions.where((a) => a.dmStatus == 'failed' || a.publicReplyStatus == 'failed').length;
    final retryableCount = job.actions.where((a) => a.canRetryDm || a.canRetryPublicReply).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Job Progress Header Card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (job.isProcessing)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primary),
                    )
                  else
                    Icon(
                      job.status == 'completed'
                          ? Icons.check_circle_rounded
                          : (job.status == 'paused' ? Icons.pause_circle_filled_rounded : Icons.info_rounded),
                      color: statusColor,
                      size: 20,
                    ),
                  const SizedBox(width: 10),
                  Text(
                    statusText,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                  const Spacer(),
                  Text(
                    '${job.processedCount} / ${job.totalComments}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: job.progressPercentage,
                  minHeight: 8,
                  backgroundColor: AppColors.panelGray,
                  valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                ),
              ),

              if (job.error != null && job.error!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (job.isPaused ? AppColors.warning : AppColors.error).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (job.isPaused ? AppColors.warning : AppColors.error).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        job.isPaused ? Icons.pause_circle_outline_rounded : Icons.error_outline_rounded,
                        size: 16,
                        color: job.isPaused ? AppColors.warning : AppColors.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          job.error!,
                          style: TextStyle(
                            fontSize: 12,
                            color: job.isPaused ? AppColors.warning : AppColors.error,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 14),
              // Comment Counts
              Row(
                children: [
                  Expanded(child: _buildJobStatBox('Total', '${job.totalComments}', AppColors.textPrimary)),
                  const SizedBox(width: 6),
                  Expanded(child: _buildJobStatBox('Processed', '${job.processedCount}', AppColors.info)),
                  const SizedBox(width: 6),
                  Expanded(child: _buildJobStatBox('Pending', '$pendingCount', AppColors.warning)),
                  const SizedBox(width: 6),
                  Expanded(child: _buildJobStatBox('Skipped', '${job.skippedCount}', AppColors.textHint)),
                ],
              ),
              const SizedBox(height: 8),
              // Action Counts
              Row(
                children: [
                  Expanded(child: _buildJobStatBox('Replies Sent', '$pubSent', AppColors.success)),
                  const SizedBox(width: 6),
                  Expanded(child: _buildJobStatBox('DMs Sent', '$dmSent', AppColors.primary)),
                  const SizedBox(width: 6),
                  Expanded(child: _buildJobStatBox('Failed Actions', '$failedActionsCount', AppColors.error)),
                  const SizedBox(width: 6),
                  Expanded(child: _buildJobStatBox('Retryable', '$retryableCount', AppColors.warning)),
                ],
              ),

              if (!job.isProcessing) ...[
                if (job.canResume) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: _isResumingJob ? null : _resumeJob,
                      icon: _isResumingJob
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.play_circle_outline_rounded, size: 18),
                      label: Text(_isResumingJob ? 'Resuming Job...' : 'Resume Job ($pendingCount Remaining)'),
                    ),
                  ),
                ],
                if (job.hasFailedActions) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.warning,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: _isRetryingJob ? null : _retryFailedActions,
                      icon: _isRetryingJob
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.replay_rounded, size: 18),
                      label: Text(_isRetryingJob ? 'Retrying Failed Actions...' : 'Retry Failed Actions ($retryableCount Retryable)'),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Action items list
        Text(
          'Processed Actions (${job.actions.length})',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
        ),
        const SizedBox(height: 10),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: job.actions.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final action = job.actions[index];
            return _buildActionOutcomeCard(action);
          },
        ),
      ],
    );
  }

  Widget _buildJobStatBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildActionOutcomeCard(BackfillActionItem action) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '@${action.username}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const Spacer(),
              _buildActionStatusBadge('Reply', action.publicReplyStatus),
              const SizedBox(width: 6),
              _buildActionStatusBadge('DM', action.dmStatus),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            action.commentText,
            style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
          ),
          if (action.isDmSkipped) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.textHint.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.textHint.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'DM Skipped: ${action.skipReason ?? action.retryReason ?? "Not eligible per Instagram rules"} (Not delivered)',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (action.isDmUnknown) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.help_outline_rounded, size: 14, color: AppColors.warning),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Delivery Unknown: Request timed out. Do not resend without verification.',
                      style: TextStyle(fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (action.publicReplyError != null || (action.dmError != null && action.isDmFailed)) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                action.dmError ?? action.publicReplyError ?? '',
                style: const TextStyle(fontSize: 11, color: AppColors.error),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionStatusBadge(String type, String status) {
    Color color;
    String label;
    IconData icon;

    switch (status) {
      case 'sent':
        color = AppColors.success;
        label = '$type: Sent';
        icon = Icons.check_circle_rounded;
        break;
      case 'skipped':
        color = const Color(0xFF64748B); // Slate
        label = '$type: Skipped (Not Eligible)';
        icon = Icons.skip_next_rounded;
        break;
      case 'unknown':
      case 'reconciliation_required':
        color = AppColors.warning;
        label = '$type: Delivery Unknown';
        icon = Icons.help_outline_rounded;
        break;
      case 'failed':
        color = AppColors.error;
        label = '$type: Failed';
        icon = Icons.cancel_rounded;
        break;
      case 'disabled':
        color = AppColors.textHint;
        label = '$type: Disabled';
        icon = Icons.block_rounded;
        break;
      case 'processing':
        color = AppColors.primary;
        label = '$type: Processing';
        icon = Icons.sync_rounded;
        break;
      default:
        color = AppColors.info;
        label = '$type: Pending';
        icon = Icons.schedule_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  // ── Bottom Action Bar ──────────────────────────────────────────────────────
  Widget? _buildBottomBar() {
    if (_activeJob != null) {
      if (_activeJob!.isProcessing) {
        return Container(
          padding: const EdgeInsets.all(16),
          color: AppColors.surface,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary)),
              SizedBox(width: 10),
              Text('Processing in background...', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            ],
          ),
        );
      }
      return SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          color: AppColors.surface,
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    setState(() => _activeJob = null);
                    _loadPreview();
                  },
                  child: const Text('Back to Preview'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => context.pop(),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_preview == null || _preview!.eligibleCount == 0) return null;

    final isInactive = _selectedAutomation?.status != 'active';
    final count = _selectedCommentIds.length;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: const Border(top: BorderSide(color: AppColors.border)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: isInactive
            ? ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.warning,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isActivating ? null : _activateAutomation,
                icon: _isActivating
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.flash_on_rounded, size: 22),
                label: Text(
                  _isActivating ? 'Activating Automation...' : 'Activate automation to process existing comments',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              )
            : ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  disabledBackgroundColor: AppColors.panelGray,
                ),
                onPressed: count == 0 || _isStartingJob ? null : _confirmAndStartJob,
                icon: _isStartingJob
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow_rounded, size: 22),
                label: Text(
                  count == 0 ? 'Select comments to process' : 'Process $count Existing Comments',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
      ),
    );
  }
}
