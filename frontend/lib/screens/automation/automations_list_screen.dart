import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/automation/automation_widgets.dart';
import '../../widgets/common/common_widgets.dart';
import '../../widgets/common/app_bottom_nav_bar.dart';

class AutomationsListScreen extends StatefulWidget {
  const AutomationsListScreen({super.key});

  @override
  State<AutomationsListScreen> createState() => _AutomationsListScreenState();
}

class _AutomationsListScreenState extends State<AutomationsListScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AutomationProvider>().fetchAutomations();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onEdit(Automation automation) {
    final provider = context.read<AutomationProvider>();
    provider.loadForEditing(automation);
    // If a post is already associated with the automation, skip post selection
    if (automation.mediaId.isNotEmpty && provider.selectedMedia != null) {
      context.push('/automation/configure-trigger');
    } else {
      context.push('/automation/select-post');
    }
  }

  Future<void> _onToggleStatus(Automation automation) async {
    final nextStatus = automation.isActive ? 'paused' : 'active';
    final success = await context.read<AutomationProvider>().updateStatus(automation.id, nextStatus);
    if (mounted && success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Automation marked as $nextStatus')),
      );
    }
  }

  Future<void> _onDelete(Automation automation) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Automation?'),
        content: const Text('Are you sure you want to delete this automation? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final success = await context.read<AutomationProvider>().deleteAutomation(automation.id);
      if (mounted && success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Automation deleted successfully')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AutomationProvider>();
    final all = provider.automations;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Keyword Automations'),
        leading: context.canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios),
                onPressed: () => context.pop(),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => provider.fetchAutomations(),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelPadding: const EdgeInsets.symmetric(horizontal: 16),
          labelColor: AppColors.primary,
          indicatorColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          tabs: [
            Tab(text: 'All (${all.length})'),
            Tab(text: 'Active (${all.where((a) => a.isActive).length})'),
            Tab(text: 'Paused (${all.where((a) => a.status == "paused").length})'),
            Tab(text: 'Drafts (${all.where((a) => a.isDraft).length})'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search automations or keywords...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
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
          ),

          // Tab content
          Expanded(
            child: provider.loadingAutomations
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildList(all),
                      _buildList(all.where((a) => a.isActive).toList()),
                      _buildList(all.where((a) => a.status == 'paused').toList()),
                      _buildList(all.where((a) => a.isDraft).toList()),
                    ],
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('New Automation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        onPressed: () {
          context.read<AutomationProvider>().startNewAutomation();
          context.push('/automation/select-post');
        },
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 2),
    );
  }

  Widget _buildList(List<Automation> items) {
    final filtered = _searchQuery.isEmpty
        ? items
        : items.where((a) {
            final nameMatch = a.name.toLowerCase().contains(_searchQuery);
            final kwMatch = a.trigger.keywords.any((k) => k.toLowerCase().contains(_searchQuery));
            final capMatch = (a.mediaCaption ?? '').toLowerCase().contains(_searchQuery);
            return nameMatch || kwMatch || capMatch;
          }).toList();

    if (filtered.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => context.read<AutomationProvider>().fetchAutomations(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 80),
            EmptyState(
              icon: Icons.auto_awesome_outlined,
              title: 'No automations found',
              subtitle: 'Create an automation or switch tabs to view others.',
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => context.read<AutomationProvider>().fetchAutomations(),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: filtered.length,
        itemBuilder: (ctx, idx) {
          final a = filtered[idx];
          return AutomationCard(
            automation: a,
            onEdit: () => _onEdit(a),
            onToggleStatus: () => _onToggleStatus(a),
            onDelete: () => _onDelete(a),
          );
        },
      ),
    );
  }
}
