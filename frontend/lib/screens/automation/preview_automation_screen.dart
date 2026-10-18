import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/automation/automation_widgets.dart';
import '../../widgets/common/common_widgets.dart';

class PreviewAutomationScreen extends StatefulWidget {
  const PreviewAutomationScreen({super.key});

  @override
  State<PreviewAutomationScreen> createState() => _PreviewAutomationScreenState();
}

class _PreviewAutomationScreenState extends State<PreviewAutomationScreen> {
  bool _saving = false;
  String? _error;

  Future<void> _save(String status) async {
    setState(() {
      _saving = true;
      _error = null;
    });

    final provider = context.read<AutomationProvider>();
    final result = await provider.saveAutomation(status: status);

    setState(() => _saving = false);

    if (result != null && mounted) {
      final isEditing = provider.editingAutomationId != null;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 32),
              ),
              const SizedBox(height: 16),
              Text(
                status == 'active'
                    ? (isEditing ? 'Automation Updated & Live!' : 'Automation Live!')
                    : (isEditing ? 'Changes Saved as Draft!' : 'Draft Saved!'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                status == 'active'
                    ? 'InstaAuto is now actively monitoring comments on this post.'
                    : 'Your automation draft has been safely saved.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      ),
                      onPressed: () {
                        Navigator.of(context).pop();
                        context.go('/dashboard');
                      },
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Dashboard', maxLines: 1),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      ),
                      onPressed: () {
                        Navigator.of(context).pop();
                        context.go('/automations');
                      },
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Automations', maxLines: 1),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    } else {
      setState(() => _error = 'Failed to save automation. Please check your network and try again.');
    }
  }

  void _showTestSimulationModal() {
    final provider = context.read<AutomationProvider>();
    final trigger  = provider.draftTrigger;
    final replies  = provider.draftPublicReply;
    final dm       = provider.draftOpeningDm;

    final testCtrl = TextEditingController(text: trigger.keywords.isNotEmpty ? trigger.keywords.first : 'price');
    String simResult = '';
    bool hasTested = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
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
                  const Expanded(
                    child: Text(
                      'Test Automation Simulation',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Type a comment to test your keyword matching and reply generation in dry-run mode (no live messages sent).',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: testCtrl,
                decoration: InputDecoration(
                  labelText: 'Test Comment Text',
                  hintText: 'e.g. Can you tell me the price?',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Run Test'),
                onPressed: () {
                  final input = testCtrl.text.toLowerCase().trim();
                  bool matched = false;

                  if (trigger.matchType == 'any') {
                    matched = true;
                  } else {
                    for (final kw in trigger.keywords) {
                      if (trigger.wholeWord) {
                        final regex = RegExp('\\b${RegExp.escape(kw)}\\b', caseSensitive: false);
                        if (regex.hasMatch(input)) {
                          matched = true;
                          break;
                        }
                      } else {
                        if (input.contains(kw.toLowerCase())) {
                          matched = true;
                          break;
                        }
                      }
                    }
                  }

                  setModalState(() {
                    hasTested = true;
                    if (matched) {
                      final rep = replies.messages.isNotEmpty ? replies.messages.first.replaceAll('@{username}', '@testuser') : 'No public reply configured';
                      simResult = '✅ MATCH DETECTED!\n\n• Public Reply: "$rep"\n• DM Sent: "${dm.message}"\n• Button: "${dm.buttonText}"';
                    } else {
                      simResult = '❌ NO MATCH. Keywords did not match this comment.';
                    }
                  });
                },
              ),
              if (hasTested) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.panelGray,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(simResult, style: const TextStyle(fontSize: 12, height: 1.4)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AutomationProvider>();
    final media    = provider.selectedMedia;
    final trigger  = provider.draftTrigger;
    final replies  = provider.draftPublicReply;
    final dm       = provider.draftOpeningDm;

    final isEditing = provider.editingAutomationId != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(isEditing ? 'Review & Save Changes' : 'Review & Activate'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/automation/configure-dm');
            }
          },
        ),
        actions: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isEditing ? AppColors.warning.withOpacity(0.12) : AppColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: isEditing ? Border.all(color: AppColors.warning.withOpacity(0.4)) : null,
              ),
              child: Text(
                isEditing ? 'Editing Mode' : 'Step 5 of 5',
                style: TextStyle(
                  fontSize: 12,
                  color: isEditing ? AppColors.warning : AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_error != null) ...[
                  ErrorBanner(message: _error!),
                  const SizedBox(height: 16),
                ],

                // Post Summary Card
                if (media != null)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 60,
                            height: 60,
                            child: media.displayUrl.isNotEmpty
                                ? CachedNetworkImage(
                                    imageUrl: media.displayUrl,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) => const Icon(Icons.image),
                                  )
                                : const Icon(Icons.image),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                media.caption?.isNotEmpty == true ? media.caption! : 'Target Post',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      media.mediaType,
                                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),

                // Trigger Summary
                AutomationPreviewCard(
                  title: trigger.matchType == 'any' ? 'All Comments Trigger' : 'Keyword Trigger',
                  subtitle: trigger.matchType == 'any'
                      ? 'Triggers on every new comment'
                      : 'Keywords: ${trigger.keywords.join(", ")} (${trigger.wholeWord ? "whole word" : "contains"})',
                  icon: Icons.tag,
                  enabled: true,
                ),
                const SizedBox(height: 12),

                // Public Reply Summary
                AutomationPreviewCard(
                  title: 'Public Comment Reply',
                  subtitle: replies.enabled
                      ? '${replies.messages.length} variation(s) configured'
                      : 'Disabled — comments will not receive public replies',
                  icon: Icons.reply,
                  enabled: replies.enabled,
                  iconColor: replies.enabled ? AppColors.success : null,
                ),
                const SizedBox(height: 12),

                // DM Summary
                AutomationPreviewCard(
                  title: 'Direct Message',
                  subtitle: dm.enabled
                      ? 'CTA: "${dm.buttonText}" → Link: ${dm.link.isNotEmpty ? dm.link : "Default"}'
                      : 'Disabled — no private DMs will be sent',
                  icon: Icons.send_outlined,
                  enabled: dm.enabled,
                  iconColor: dm.enabled ? AppColors.warning : null,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),

          // Bottom Bar
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
                    onPressed: _saving ? null : () => _save('draft'),
                    child: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Save Draft'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: GradientButton(
                    label: _saving
                        ? 'Saving...'
                        : (isEditing ? 'Update & Activate' : 'Activate Automation'),
                    icon: Icons.check_circle_outline,
                    onPressed: _saving ? null : () => _save('active'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
