import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/firebase_service.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final GlobalKey<_DispatchBoardState> _dispatchBoardKey = GlobalKey<_DispatchBoardState>();
  final FirebaseService _firebaseService = FirebaseService();

  final List<String> _authorizedUsers = [
    'tdear@immediateresponsehvac.ca',
    'nicole@immediateresponsehvac.ca',
    'cory@immediateresponsehvac.ca',
    'admin@immediateresponsehvac.ca',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 1);
    _tabController.addListener(() {
      setState(() {}); // Rebuild when tab changes to show/hide nav buttons
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userEmail = FirebaseAuth.instance.currentUser?.displayName?.toLowerCase();
    if (userEmail == null || !_authorizedUsers.contains(userEmail)) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0F1C),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.security, size: 64, color: Colors.redAccent),
              const SizedBox(height: 24),
              const Text(
                'ACCESS DENIED',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'You must be logged in as an authorized administrator.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => context.go('/tech/login'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
                child: const Text('Go to Login', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Operations', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF3498DB),
        foregroundColor: Colors.white,
        actions: [
          if (_tabController.index == 1) ...[
            TextButton.icon(
              onPressed: () => _dispatchBoardKey.currentState?.backward(),
              icon: const Icon(Icons.keyboard_arrow_left, color: Colors.white),
              label: const Text('Previous 4 Days', style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
            TextButton(
              onPressed: () => _dispatchBoardKey.currentState?.today(),
              child: const Text('TODAY', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            TextButton.icon(
              onPressed: () => _dispatchBoardKey.currentState?.forward(),
              icon: const Icon(Icons.keyboard_arrow_right, color: Colors.white),
              label: const Text('Next 4 Days', style: TextStyle(color: Colors.white, fontSize: 12)),
              iconAlignment: IconAlignment.end,
            ),
            const SizedBox(width: 8),
          ],
          IconButton(
            onPressed: () => GoRouter.of(context).push('/tech'),
            icon: const Icon(Icons.handyman),
            tooltip: 'Tech App',
          ),
          IconButton(
            onPressed: () => GoRouter.of(context).push('/admin/intake'),
            icon: const Icon(Icons.add_box),
            tooltip: 'New Lead Intake',
          ),
          IconButton(
            onPressed: () => GoRouter.of(context).push('/admin/po-workbench'),
            icon: const Icon(Icons.receipt_long),
            tooltip: 'PO Workbench',
          ),
          IconButton(
            onPressed: () => GoRouter.of(context).push('/admin/pm-database'),
            icon: const Icon(Icons.people_alt),
            tooltip: 'PM Database',
          ),
          IconButton(
            onPressed: () => _addTestLead(context),
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Debug: Add Test Lead',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'LEAD MANAGEMENT', icon: Icon(Icons.assignment_ind)),
            Tab(text: 'DISPATCH BOARD', icon: Icon(Icons.dashboard_customize)),
            Tab(text: 'FOR REVIEW', icon: Icon(Icons.fact_check)),
          ],
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildOpsManagementTab(_firebaseService),
          DispatchBoard(key: _dispatchBoardKey),
          _buildReviewTab(_firebaseService),
        ],
      ),
    );
  }

  Widget _buildOpsManagementTab(FirebaseService firebaseService) {
    return StreamBuilder<QuerySnapshot>(
      stream: firebaseService.getOpsManagementLeads(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final leads = snapshot.data?.docs ?? [];
        if (leads.isEmpty) return _buildEmptyState('No active leads to display.');

        final unscheduled = leads.where((l) => ['intake', 'to-be-scheduled', 'quote-to-be-sent'].contains((l.data() as Map)['status'])).toList();
        final scheduled = leads.where((l) => ['assigned', 'scheduled', 'in-progress'].contains((l.data() as Map)['status'])).toList();
        final waitingForReport = leads.where((l) => ['waiting-for-report'].contains((l.data() as Map)['status'])).toList();
        final reportArrived = leads.where((l) => ['report-submitted', 'report-arrived'].contains((l.data() as Map)['status'])).toList();
        final reportSent = leads.where((l) => ['report-sent'].contains((l.data() as Map)['status'])).toList();
        final quoteSent = leads.where((l) => ['quote-sent'].contains((l.data() as Map)['status'])).toList();

        Widget buildSection(String title, List<QueryDocumentSnapshot> sectionLeads, Color color) {
          if (sectionLeads.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0, top: 8.0),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: color.withOpacity(0.5)),
                      ),
                      child: Text(
                        '$title (${sectionLeads.length})',
                        style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
              ...sectionLeads.map((lead) {
                final data = lead.data() as Map<String, dynamic>;
                return _LeadCard(leadId: lead.id, data: data, isReview: false);
              }),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            buildSection('UNSCHEDULED / ACTION REQUIRED', unscheduled, Colors.redAccent),
            buildSection('SCHEDULED', scheduled, Colors.orange),
            buildSection('WAITING FOR REPORT', waitingForReport, Colors.purpleAccent),
            buildSection('REPORT ARRIVED', reportArrived, Colors.green),
            buildSection('REPORT SENT', reportSent, Colors.teal),
            buildSection('QUOTE SENT', quoteSent, Colors.blue),
          ],
        );
      },
    );
  }

  Widget _buildReviewTab(FirebaseService firebaseService) {
    return StreamBuilder<QuerySnapshot>(
      stream: firebaseService.getReportsForReview(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final leads = snapshot.data?.docs ?? [];
        if (leads.isEmpty) return _buildEmptyState('No reports pending review.');

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: leads.length,
          itemBuilder: (context, index) {
            final lead = leads[index];
            final data = lead.data() as Map<String, dynamic>;
            return _LeadCard(leadId: lead.id, data: data, isReview: true);
          },
        );
      },
    );
  }

  Future<void> _addTestLead(BuildContext context) async {
    final firebaseService = FirebaseService();
    await firebaseService.createTestLead();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test lead added to INTAKE')),
      );
    }
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.inbox_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: Colors.grey, fontSize: 16)),
        ],
      ),
    );
  }
}

class _LeadCard extends StatelessWidget {
  final String leadId;
  final Map<String, dynamic> data;
  final bool isReview;

  const _LeadCard({required this.leadId, required this.data, required this.isReview});

  Future<void> _retryIntake(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Retrying intake logic...')),
    );
    final success = await FirebaseService().retryLeadIntake(leadId);
    if (!context.mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Retry successful!'), backgroundColor: Colors.green),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Retry failed. Please check logs.'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = isReview ? Colors.green : Colors.blue;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    data['property_address'] ?? 'No Address',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.sync, color: Colors.blue),
                  tooltip: 'Retry Sync',
                  onPressed: () => _retryIntake(context),
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: 'Delete Lead',
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Delete Lead'),
                        content: const Text('Are you sure you want to delete this lead? This action cannot be undone.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('CANCEL'),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                            child: const Text('DELETE', style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true && context.mounted) {
                      await FirebaseService().deleteLead(leadId);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Lead deleted')),
                        );
                      }
                    }
                  },
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    (data['status']?.toString() ?? 'INTAKE').toUpperCase(),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Client: ${data['pm'] != null && data['pm'] is Map && data['pm']['company_name'] != null && data['pm']['company_name'].toString().isNotEmpty ? data['pm']['company_name'] : (data['client_name'] ?? 'Unknown')}', style: TextStyle(color: Colors.grey[700])),
            if (isReview)
              Text('Invoiced By: ${data['technician_name'] ?? 'Tech'}', style: TextStyle(color: Colors.grey[700]))
            else
              Text('Requested: ${data['visit_requested'] ?? 'Not specified'}', style: TextStyle(color: Colors.grey[700])),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => GoRouter.of(context).push('/admin/estimate/$leadId'),
                  icon: const Icon(Icons.request_quote),
                  label: const Text('QUOTE'),
                  style: TextButton.styleFrom(foregroundColor: Colors.orange),
                ),
                const SizedBox(width: 8),
                if (isReview)
                  ElevatedButton.icon(
                    onPressed: () => GoRouter.of(context).push('/admin/review/$leadId'),
                    icon: const Icon(Icons.fact_check),
                    label: const Text('REVIEW REPORT'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: () => _showSchedulingModal(context),
                    icon: const Icon(Icons.calendar_month),
                    label: const Text('SCHEDULE TECH'),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFE67E22)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSchedulingModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => SchedulingModal(
        leadId: leadId, 
        propertyAddress: data['property_address'] ?? 'Service Job',
        initialJobDuration: data['job_duration'],
        initialIncludeWeekends: data['include_weekends'],
        calendarUrl: data['calendar_event_url'],
        description: 'Client: ${data['client_name'] ?? 'Unknown'}\nPhone: ${data['client_cell'] ?? 'Unknown'}\nScope: ${data['scope_details'] ?? ''}',
      ),
    );
  }
}

class SchedulingModal extends StatefulWidget {
  final String leadId;
  final String propertyAddress;
  final DateTime? initialDate;
  final List<String>? initialTechEmails;
  final int? initialJobDuration;
  final bool? initialIncludeWeekends;
  final String? calendarUrl;
  final String? description;

  const SchedulingModal({
    super.key, 
    required this.leadId, 
    required this.propertyAddress,
    this.initialDate,
    this.initialTechEmails,
    this.initialJobDuration,
    this.initialIncludeWeekends,
    this.calendarUrl,
    this.description,
  });

  @override
  State<SchedulingModal> createState() => _SchedulingModalState();
}

class _SchedulingModalState extends State<SchedulingModal> {
  String? selectedTechEmail;
  String? selectedTechName;
  late DateTime selectedDate;
  late TimeOfDay selectedTime;
  bool isSaving = false;
  int _shiftDurationHours = 3;
  int _shiftDurationDays = 0;
  bool _skipWeekends = true;

  final List<Map<String, dynamic>> technicians = [
    {'name': 'Berkant', 'email': 'berkant@immediateresponsehvac.ca', 'color': Colors.red},
    {'name': 'Deniz', 'email': 'deniz@immediateresponsehvac.ca', 'color': Colors.green},
    {'name': 'Dominik', 'email': 'dominik@immediateresponsehvac.ca', 'color': Colors.orange},
    {'name': 'Evan', 'email': 'evan@immediateresponsehvac.ca', 'color': Colors.purple},
    {'name': 'HD HVAC', 'email': 'hdhvac@hotmail.com', 'color': Colors.teal},
    {'name': 'Hikmet', 'email': 'hikmet@immediateresponsehvac.ca', 'color': Colors.indigo},
    {'name': 'Info', 'email': 'info@idealmechanical.ca', 'color': Colors.pink},
    {'name': 'Jordan', 'email': 'jordan@immediateresponsehvac.ca', 'color': Colors.cyan},
    {'name': 'Jude', 'email': 'jude@immediateresponsehvac.ca', 'color': Colors.brown},
    {'name': 'Omar', 'email': 'omar@immediateresponsehvac.ca', 'color': Colors.deepOrange},
    {'name': 'Randy', 'email': 'randy@immediateresponsehvac.ca', 'color': Colors.amber},
    {'name': 'Richard', 'email': 'richard@immediateresponsehvac.ca', 'color': Colors.lime},
      {'name': 'Cory', 'email': 'cory@immediateresponsehvac.ca', 'color': Colors.blue},
      {'name': 'Tyler', 'email': 'tyler@immediateresponsehvac.ca', 'color': Colors.blue},
      {'name': 'TDear', 'email': 'tdear@immediateresponsehvac.ca', 'color': Colors.blueGrey},
  ];

  @override
  void initState() {
    super.initState();
    selectedDate = widget.initialDate ?? DateTime.now().add(const Duration(days: 1));
    selectedTime = widget.initialDate != null 
        ? TimeOfDay(hour: widget.initialDate!.hour, minute: widget.initialDate!.minute)
        : const TimeOfDay(hour: 9, minute: 0);

    if (widget.initialJobDuration != null) {
      _shiftDurationDays = (widget.initialJobDuration! - 1).clamp(0, 7);
    }
    if (widget.initialIncludeWeekends != null) {
      _skipWeekends = !widget.initialIncludeWeekends!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.all(0),
      contentPadding: const EdgeInsets.all(24),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: 24, top: 24, right: 16),
              child: Text(
                'Schedule Technician',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 8),
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.black, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
      content: Container(
        width: 500,
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.9),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.propertyAddress, style: const TextStyle(color: Colors.grey)),
          if (widget.description != null && widget.description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
              child: Text(widget.description!, style: const TextStyle(fontSize: 13, color: Colors.black87)),
            ),
          ],
          if (widget.calendarUrl != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final url = Uri.parse(widget.calendarUrl!);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url);
                }
              },
              icon: const Icon(Icons.open_in_new, color: Colors.blue),
              label: const Text('OPEN IN GOOGLE CALENDAR', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
            ),
          ],
          const SizedBox(height: 24),
          
          if (widget.initialTechEmails != null && widget.initialTechEmails!.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Currently Assigned:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 8),
                ...widget.initialTechEmails!.map((email) {
                  final tech = technicians.firstWhere((t) => t['email'].toLowerCase() == email.toLowerCase(), orElse: () => {'name': email});
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person, color: Colors.black54),
                    title: Text(tech['name'], style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    subtitle: Text(email, style: const TextStyle(color: Colors.black87)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () async {
                        setState(() => isSaving = true);
                        final success = await FirebaseService().removeTech(leadId: widget.leadId, techEmail: email);
                        setState(() => isSaving = false);
                        if (success && mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Removed technician')));
                        }
                      },
                    ),
                  );
                }),
                const Divider(),
                const SizedBox(height: 8),
              ],
            ),

          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('leads')
                .where('status', whereIn: ['assigned', 'scheduled', 'in-progress'])
                .snapshots(),
            builder: (context, snapshot) {
              final activeLeads = snapshot.data?.docs ?? [];
              int selectedTechTotal = 0;
              if (selectedTechEmail != null) {
                selectedTechTotal = activeLeads.where((doc) {
                  final dynamic techData = (doc.data() as Map)['technician_email'];
                  if (techData is String) {
                     return techData.toLowerCase().contains(selectedTechEmail!.toLowerCase());
                  } else if (techData is List) {
                     return techData.map((e) => e.toString().toLowerCase()).contains(selectedTechEmail!.toLowerCase());
                  }
                  return false;
                }).length;
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.analytics_outlined, color: Colors.blue, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Assigned Jobs Today: $selectedTechTotal',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Select Additional/New Technician', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    value: selectedTechEmail,
                    items: technicians.map<DropdownMenuItem<String>>((tech) {
                      final email = tech['email'] as String;
                      final individualCount = activeLeads.where((doc) {
                        final techData = (doc.data() as Map)['technician_email'];
                        if (techData is String) return techData.toLowerCase() == email.toLowerCase();
                        if (techData is List) return techData.map((e) => e.toString().toLowerCase()).contains(email.toLowerCase());
                        return false;
                      }).length;

                      return DropdownMenuItem<String>(
                        value: email,
                        child: Text('${tech['name']} ($individualCount jobs)'),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        selectedTechEmail = val;
                        selectedTechName = technicians.firstWhere((t) => t['email'] == val)['name'];
                      });
                    },
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (date != null) setState(() => selectedDate = date);
                  },
                  icon: const Icon(Icons.date_range),
                  label: Text(DateFormat('MMM dd, yyyy').format(selectedDate)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: selectedTime,
                    );
                    if (time != null) setState(() => selectedTime = time);
                  },
                  icon: const Icon(Icons.access_time),
                  label: Text(selectedTime.format(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Additional Days', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.calendar_today),
                      ),
                      value: _shiftDurationDays,
                      items: [0, 1, 2, 3, 4, 5, 6, 7].map((days) {
                        return DropdownMenuItem<int>(
                          value: days,
                          child: Text(days == 0 ? 'Same Day' : '+$days Day(s)'),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _shiftDurationDays = val);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Shift Duration', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.timer),
                      ),
                      value: _shiftDurationHours,
                      items: [2, 4, 6, 8, 10, 12, 24].map((hours) {
                        return DropdownMenuItem<int>(
                          value: hours,
                          child: Text('$hours Hours'),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _shiftDurationHours = val);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_shiftDurationDays > 0)
            CheckboxListTile(
              title: const Text('Skip Weekends'),
              subtitle: const Text('Only schedule on Mon-Fri'),
              value: _skipWeekends,
              onChanged: (val) {
                if (val != null) setState(() => _skipWeekends = val);
              },
            ),
          const SizedBox(height: 32),

          ElevatedButton(
            onPressed: isSaving ? null : _handleSave,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE67E22),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: isSaving
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('UPDATE EVENT', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: isSaving ? null : _handleUnschedule,
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('DELETE EVENT (UNSCHEDULE)', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 32),
        ],
      ),
      ),
      ),
    );
  }

  Future<void> _handleSave() async {
    setState(() => isSaving = true);
    final scheduledDateTime = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    bool success = true;

    String? recurrenceRule;
    if (_shiftDurationDays > 0) {
      if (_skipWeekends) {
        recurrenceRule = 'FREQ=DAILY;INTERVAL=1;COUNT=${_shiftDurationDays + 1};BYDAY=MO,TU,WE,TH,FR';
      } else {
        recurrenceRule = 'FREQ=DAILY;INTERVAL=1;COUNT=${_shiftDurationDays + 1}';
      }
    }

    // Always reschedule the event time
    success = await FirebaseService().rescheduleEvent(
      leadId: widget.leadId,
      startTime: scheduledDateTime,
      endTime: scheduledDateTime.add(Duration(hours: _shiftDurationHours)),
      recurrenceRule: recurrenceRule,
    );

    // If a new tech was selected, assign them
    if (selectedTechEmail != null && selectedTechName != null && success) {
      success = await FirebaseService().assignTech(
        leadId: widget.leadId,
        techEmail: selectedTechEmail!,
        techName: selectedTechName!,
        scheduledTime: scheduledDateTime,
      );
    }

    if (mounted) {
      setState(() => isSaving = false);
      if (success) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Updated successfully!'), backgroundColor: Colors.green),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update. Check logs.'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleUnschedule() async {
    setState(() => isSaving = true);
    final success = await FirebaseService().unscheduleEvent(leadId: widget.leadId);
    
    if (mounted) {
      setState(() => isSaving = false);
      if (success) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Event deleted and returned to unassigned leads.'), backgroundColor: Colors.green),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to unschedule event. Check logs.'), backgroundColor: Colors.red),
        );
      }
    }
  }
}

class DispatchBoard extends StatefulWidget {
  const DispatchBoard({super.key});

  @override
  State<DispatchBoard> createState() => _DispatchBoardState();
}

class _DispatchBoardState extends State<DispatchBoard> {
  late CalendarController _calendarController;
  final FirebaseService _firebaseService = FirebaseService();
  bool _isInit = false;
  bool isSyncing = false;
  String _searchQuery = '';
  DateTime? _lastCellTapTime;
  DateTime? _lastCellTapDate;
  String? _lastCellTapResource;
  DateTime? _lastRawTapTime;
  late List<Map<String, dynamic>> technicians;
  List<Map<String, dynamic>> _googleEvents = [];
  late Stream<QuerySnapshot> _scheduledLeadsStream;

  void _fetchGoogleEvents() async {
    final events = await _firebaseService.getGoogleCalendarEvents();
    if (mounted) {
      setState(() {
        _googleEvents = events;
      });
    }
  }

  void forward() {
    setState(() {
      final current = _calendarController.displayDate ?? DateTime.now();
      _calendarController.displayDate = current.add(const Duration(days: 4));
    });
  }

  void backward() {
    setState(() {
      final current = _calendarController.displayDate ?? DateTime.now();
      _calendarController.displayDate = current.subtract(const Duration(days: 4));
    });
  }

  void today() {
    setState(() {
      _calendarController.displayDate = DateTime.now();
    });
  }

  @override
  void initState() {
    super.initState();
    _calendarController = CalendarController();
    _calendarController.displayDate = DateTime.now();
    _scheduledLeadsStream = _firebaseService.getScheduledLeads();
    
    // Initialize roster inside initState for safety
    technicians = [
      {'name': 'Berkant', 'email': 'berkant@immediateresponsehvac.ca', 'color': Colors.red},
      {'name': 'Deniz', 'email': 'deniz@immediateresponsehvac.ca', 'color': Colors.green},
      {'name': 'Dominik', 'email': 'dominik@immediateresponsehvac.ca', 'color': Colors.orange},
      {'name': 'Evan', 'email': 'evan@immediateresponsehvac.ca', 'color': Colors.purple},
      {'name': 'HD HVAC', 'email': 'hdhvac@hotmail.com', 'color': Colors.teal},
      {'name': 'Hikmet', 'email': 'hikmet@immediateresponsehvac.ca', 'color': Colors.indigo},
      {'name': 'Info', 'email': 'info@idealmechanical.ca', 'color': Colors.pink},
      {'name': 'Jordan', 'email': 'jordan@immediateresponsehvac.ca', 'color': Colors.cyan},
      {'name': 'Jude', 'email': 'jude@immediateresponsehvac.ca', 'color': Colors.brown},
      {'name': 'Omar', 'email': 'omar@immediateresponsehvac.ca', 'color': Colors.deepOrange},
      {'name': 'Randy', 'email': 'randy@immediateresponsehvac.ca', 'color': Colors.amber},
      {'name': 'Richard', 'email': 'richard@immediateresponsehvac.ca', 'color': Colors.lime},
      {'name': 'Cory', 'email': 'cory@immediateresponsehvac.ca', 'color': Colors.blue},
      {'name': 'Tyler', 'email': 'tyler@immediateresponsehvac.ca', 'color': Colors.blue},
      {'name': 'TDear', 'email': 'tdear@immediateresponsehvac.ca', 'color': Colors.blueGrey},
    ];

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _isInit = true);
    });
    _fetchGoogleEvents();
  }

  @override
  void dispose() {
    _calendarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) {
      return const Center(child: CircularProgressIndicator());
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 768;
    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          children: [
            // Sidebar: Unassigned Leads
            if (!isMobile)
              Container(
                width: 300,
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: Colors.grey[300]!)),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: Colors.grey[100],
                      child: const Row(
                        children: [
                          Icon(Icons.list_alt, size: 20),
                          SizedBox(width: 8),
                          Text('UNASSIGNED LEADS', style: TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: StreamBuilder<QuerySnapshot>(
                        stream: _firebaseService.getIntakeLeads(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                          final leads = snapshot.data?.docs ?? [];
                          if (leads.isEmpty) return const Center(child: Text('No unassigned leads.', style: TextStyle(color: Colors.grey)));
                          
                          return ListView.builder(
                            itemCount: leads.length,
                            itemBuilder: (context, index) {
                              final lead = leads[index];
                              final data = lead.data() as Map<String, dynamic>;
                              return Draggable<Map<String, dynamic>>(
                                data: {'id': lead.id, 'data': data},
                                feedback: Material(
                                  elevation: 8,
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    width: 250,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE67E22),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(data['property_address'] ?? 'New Job', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                                childWhenDragging: Opacity(opacity: 0.5, child: _SidebarLeadCard(data: data)),
                                child: _SidebarLeadCard(data: data),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            
            // Main Board
            Expanded(
              child: Column(
                children: [
                  // Toolbar: Search Bar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: InputDecoration(
                              hintText: 'Search calendar events by address, name...',
                              prefixIcon: const Icon(Icons.search),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(vertical: 0),
                            ),
                            onChanged: (val) => setState(() => _searchQuery = val.toLowerCase()),
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Status Bar (Syncing only)
                  if (isSyncing)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      color: Colors.orange[50],
                      width: double.infinity,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 8),
                          Text('SYNCING GOOGLE CALENDAR...', style: TextStyle(color: Colors.orange[800], fontWeight: FontWeight.bold, fontSize: 11)),
                        ],
                      ),
                    ),
                  
                  // Calendar wrapped in DragTarget
                  Expanded(
                    child: DragTarget<Map<String, dynamic>>(
                      onWillAcceptWithDetails: (details) => true,
                      onAcceptWithDetails: (details) async {
                        _showDropConfirmation(details.data, details.offset);
                      },
                      builder: (context, candidateData, rejectedData) {
                        return StreamBuilder<QuerySnapshot>(
                          stream: _scheduledLeadsStream,
                          builder: (context, snapshot) {
                            var leads = snapshot.data?.docs ?? [];
                            var filteredGoogleEvents = _googleEvents;

                            // Filter by search query
                            if (_searchQuery.isNotEmpty) {
                              final queryStr = _searchQuery.trim();
                              final queryTokens = queryStr.split(RegExp(r'\s+'));

                              leads = leads.where((doc) {
                                final data = doc.data() as Map<String, dynamic>;
                                final pmName = data['pm'] != null && data['pm'] is Map ? (data['pm']['company_name'] ?? '') : '';
                                final pmFullName = data['pm'] != null && data['pm'] is Map ? (data['pm']['full_name'] ?? '') : '';
                                final searchStr = '${data['property_address'] ?? ''} ${data['client_name'] ?? ''} ${data['technician'] ?? ''} ${data['technician_email'] ?? ''} $pmName $pmFullName'.toLowerCase();
                                return queryTokens.every((token) => searchStr.contains(token));
                              }).toList();

                              filteredGoogleEvents = _googleEvents.where((event) {
                                final searchStr = '${event['summary'] ?? ''} ${event['description'] ?? ''} ${event['location'] ?? ''}'.toLowerCase();
                                return queryTokens.every((token) => searchStr.contains(token));
                              }).toList();
                            }

                            final dataSource = _LeadDataSource(leads, technicians, filteredGoogleEvents);
                            
                            CalendarView calendarView = CalendarView.timelineDay;
                            if (isMobile) {
                              calendarView = isPortrait ? CalendarView.schedule : CalendarView.timelineDay;
                            }

                            // Do NOT override the default size for ResourceViewSettings.
                            // The ghost events are automatically split into multiple ghost rows by _LeadDataSource
                            // so the Unassigned section grows dynamically, while normal techs stay at original size.
                            double fontSize = isMobile ? 9.5 : 11.0;

                            return SfCalendar(
                              view: calendarView,
                              controller: _calendarController,
                              headerHeight: 0,
                              todayHighlightColor: const Color(0xFFE67E22),
                              timeSlotViewSettings: const TimeSlotViewSettings(
                                startHour: 7,
                                endHour: 20,
                                timeInterval: Duration(hours: 2),
                                timeIntervalHeight: 65,
                                numberOfDaysInView: 4,
                                timeFormat: 'h a',
                              ),
                              resourceViewSettings: ResourceViewSettings(
                                showAvatar: false,
                                displayNameTextStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: fontSize + 2),
                              ),
                              dataSource: dataSource,
                              allowAppointmentResize: !isMobile, // Disable dragging/resizing on mobile for better touch scrolling
                              allowDragAndDrop: !isMobile,
                              onAppointmentResizeEnd: (AppointmentResizeEndDetails details) {
                                _handleResize(details);
                              },
                              onDragEnd: (AppointmentDragEndDetails details) {
                                _handleReschedule(details);
                              },
                              onTap: (CalendarTapDetails details) {
                                if (details.targetElement == CalendarElement.appointment && details.appointments != null && details.appointments!.isNotEmpty) {
                                  final appointment = details.appointments!.first as Appointment;
                                  final leadId = appointment.id as String;
                                  Map<String, dynamic>? leadData;
                                  try {
                                    final leadDoc = leads.firstWhere((doc) => doc.id == leadId);
                                    leadData = leadDoc.data() as Map<String, dynamic>;
                                  } catch (_) {}

                                  Map<String, dynamic>? googleEventData;
                                  try {
                                    googleEventData = filteredGoogleEvents.firstWhere((e) => e['id'] == leadId);
                                  } catch (_) {}

                                  String? calUrl = leadData?['calendar_event_url'] ?? googleEventData?['htmlLink'];
                                  String desc = appointment.notes ?? '';
                                  if (leadData != null) {
                                    desc = 'Client: ${leadData['client_name'] ?? 'Unknown'}\nPhone: ${leadData['client_cell'] ?? 'Unknown'}\nScope: ${leadData['scope_details'] ?? ''}';
                                  }

                                  showDialog(
                                    context: context,
                                    builder: (context) => SchedulingModal(
                                      leadId: leadId,
                                      propertyAddress: appointment.subject,
                                      initialDate: appointment.startTime,
                                      initialTechEmails: appointment.resourceIds?.map((e) => e.toString()).toList(),
                                      initialJobDuration: leadData?['job_duration'],
                                      initialIncludeWeekends: leadData?['include_weekends'],
                                      calendarUrl: calUrl,
                                      description: desc,
                                    ),
                                  );
                                } else if (details.targetElement == CalendarElement.calendarCell && details.resource != null) {
                                  if (details.resource!.id != 'unassigned_ghost') {
                                    final now = DateTime.now();

                                    // 1. Debounce framework ghost taps (bouncing pointer events)
                                    // If a tap fires within 150ms of the LAST RAW TAP, it is a hardware/framework bounce of the same physical click.
                                    if (_lastRawTapTime != null && now.difference(_lastRawTapTime!).inMilliseconds < 150) {
                                      _lastRawTapTime = now;
                                      return; // Ignore this ghost tap completely.
                                    }
                                    _lastRawTapTime = now;

                                    // 2. Process valid, distinct human taps for double-click logic.
                                    final tapDate = details.date;
                                    final tapResource = details.resource!.id as String;

                                    if (_lastCellTapTime != null && _lastCellTapDate == tapDate && _lastCellTapResource == tapResource) {
                                      final diff = now.difference(_lastCellTapTime!);
                                      if (diff.inMilliseconds < 500) {
                                        // Valid double click on the exact same cell!
                                        _lastCellTapTime = null;
                                        _lastCellTapDate = null;
                                        _lastCellTapResource = null;
                                        showDialog(
                                          context: context,
                                          builder: (context) => AssignLeadFromCalendarModal(
                                            selectedTime: tapDate ?? DateTime.now(),
                                            techEmail: tapResource,
                                            technicians: technicians,
                                          ),
                                        );
                                      } else {
                                        // Too slow, reset for new double click
                                        _lastCellTapTime = now;
                                        _lastCellTapDate = tapDate;
                                        _lastCellTapResource = tapResource;
                                      }
                                    } else {
                                      // First click of a potential double click on this specific cell
                                      _lastCellTapTime = now;
                                      _lastCellTapDate = tapDate;
                                      _lastCellTapResource = tapResource;
                                    }
                                  }
                                }
                              },
                              appointmentBuilder: (context, details) {
                                final appointment = details.appointments.first as Appointment;
                                return MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onDoubleTap: () {
                                      final leadId = appointment.id.toString();
                                      Map<String, dynamic>? leadData;
                                      try {
                                        final leadDoc = leads.firstWhere((doc) => doc.id == leadId);
                                        leadData = leadDoc.data() as Map<String, dynamic>;
                                      } catch (_) {}

                                      Map<String, dynamic>? googleEventData;
                                      try {
                                        googleEventData = _googleEvents.firstWhere((e) => e['id'] == leadId);
                                      } catch (_) {}

                                      String? calUrl = leadData?['calendar_event_url'] ?? googleEventData?['htmlLink'];
                                      String desc = appointment.notes ?? '';
                                      if (leadData != null) {
                                        desc = 'Client: ${leadData['client_name'] ?? 'Unknown'}\nPhone: ${leadData['client_cell'] ?? 'Unknown'}\nScope: ${leadData['scope_details'] ?? ''}';
                                      }

                                      showDialog(
                                        context: context,
                                        builder: (context) => SchedulingModal(
                                          leadId: leadId,
                                          propertyAddress: appointment.subject,
                                          initialDate: appointment.startTime,
                                          initialTechEmails: appointment.resourceIds?.map((e) => e.toString()).toList(),
                                          initialJobDuration: leadData?['job_duration'],
                                          initialIncludeWeekends: leadData?['include_weekends'],
                                          calendarUrl: calUrl,
                                          description: desc,
                                        ),
                                      );
                                    },
                                    child: Container(
                                      width: details.bounds.width,
                                      height: details.bounds.height,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: appointment.color,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border(left: BorderSide(color: Colors.white.withOpacity(0.5), width: 3)),
                                      ),
                                      child: SingleChildScrollView(
                                        child: Text(
                                          appointment.notes != null && appointment.notes!.isNotEmpty 
                                              ? '${appointment.subject}\n${appointment.notes}'
                                              : appointment.subject,
                                          softWrap: true,
                                          style: TextStyle(
                                            color: appointment.color.computeLuminance() > 0.20 || appointment.color == Colors.limeAccent || appointment.color == Colors.limeAccent.shade700 ? Colors.black : Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11,
                                            height: 1.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            ],
        );
      },
    );
  }

  void _showDropConfirmation(Map<String, dynamic> leadData, Offset offset) {
    // Ideally we would hit test the point to get Resource/Time.
    // For now, since hit testing SfCalendar externally is complex,
    // we open a quick modal to select Tech/Time but pre-filled.
    showDialog(
      context: context,
      builder: (context) => SchedulingModal(
        leadId: leadData['id'],
        propertyAddress: leadData['data']['property_address'] ?? 'New Job',
        initialJobDuration: leadData['data']['job_duration'],
        initialIncludeWeekends: leadData['data']['include_weekends'],
        calendarUrl: leadData['data']['calendar_event_url'],
        description: 'Client: ${leadData['data']['client_name'] ?? 'Unknown'}\nPhone: ${leadData['data']['client_cell'] ?? 'Unknown'}\nScope: ${leadData['data']['scope_details'] ?? ''}',
      ),
    );
  }

  void _handleReschedule(AppointmentDragEndDetails details) async {
    final appointment = details.appointment as Appointment?;
    if (appointment == null || details.droppingTime == null) return;

    final leadId = appointment.id as String;
    final newStartTime = details.droppingTime!;
    final duration = appointment.endTime.difference(appointment.startTime);
    final newEndTime = newStartTime.add(duration);

    setState(() => isSyncing = true);
    
    // Always reschedule the time
    bool success = await _firebaseService.rescheduleEvent(
      leadId: leadId,
      startTime: newStartTime,
      endTime: newEndTime,
      recurrenceRule: appointment.recurrenceRule,
    );

    // Handle resource (tech) change if dragged to a different column
    if (details.targetResource != null) {
      final newTechEmail = (details.targetResource!.id as String).toLowerCase();
      final oldTechEmails = appointment.resourceIds?.map((id) => id.toString().toLowerCase()).toList() ?? [];
      
      if (!oldTechEmails.contains(newTechEmail)) {
        for (final oldEmail in oldTechEmails) {
          await _firebaseService.removeTech(leadId: leadId, techEmail: oldEmail);
        }
        success = await _firebaseService.assignTech(
          leadId: leadId,
          techEmail: newTechEmail,
          techName: details.targetResource!.displayName,
          scheduledTime: newStartTime, 
        );
        // Re-apply the duration since assignTech defaults to 4 hours on backend
        await _firebaseService.rescheduleEvent(
          leadId: leadId,
          startTime: newStartTime,
          endTime: newEndTime,
          recurrenceRule: appointment.recurrenceRule,
        );
      }
    }

    if (mounted) {
      setState(() => isSyncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Rescheduled & Synced with Google Calendar' : 'Sync failed. Retry.'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _handleResize(AppointmentResizeEndDetails details) async {
    final appointment = details.appointment as Appointment?;
    if (appointment == null || details.startTime == null || details.endTime == null) return;

    final leadId = appointment.id as String;

    setState(() => isSyncing = true);
    
    final success = await _firebaseService.rescheduleEvent(
      leadId: leadId,
      startTime: details.startTime!,
      endTime: details.endTime!,
      recurrenceRule: appointment.recurrenceRule,
    );

    if (mounted) {
      setState(() => isSyncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Resized & Synced with Google Calendar' : 'Sync failed. Retry.'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }
}

class _SidebarLeadCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _SidebarLeadCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(data['property_address'] ?? 'No Address', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.person, size: 12, color: Colors.grey),
                const SizedBox(width: 4),
                Text(data['pm'] != null && data['pm'] is Map && data['pm']['company_name'] != null && data['pm']['company_name'].toString().isNotEmpty ? data['pm']['company_name'] : (data['client_name'] ?? 'Unknown'), style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
              child: const Text('INTAKE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.orange)),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeadDataSource extends CalendarDataSource {
  _LeadDataSource(List<QueryDocumentSnapshot> leads, List<Map<String, dynamic>> technicians, List<Map<String, dynamic>> googleEvents) {
    int ghostRowCounter = 0;
    final Map<String, List<DateTime>> ghostRowEnds = {};

    String assignGhostRow(DateTime start, DateTime end) {
      final dateKey = '${start.year}-${start.month}-${start.day}';
      if (!ghostRowEnds.containsKey(dateKey)) ghostRowEnds[dateKey] = [];
      final ends = ghostRowEnds[dateKey]!;
      for (int i = 0; i < ends.length; i++) {
        if (!start.isBefore(ends[i])) {
          ends[i] = end;
          if (i >= ghostRowCounter) ghostRowCounter = i + 1;
          return 'unassigned_ghost_$i';
        }
      }
      ends.add(end);
      final newRow = ends.length - 1;
      if (newRow >= ghostRowCounter) ghostRowCounter = newRow + 1;
      return 'unassigned_ghost_$newRow';
    }

    appointments = leads.map((doc) {
      try {
        final data = doc.data() as Map<String, dynamic>;
        
        final dynamic techData = data['technician_email'];
        List<String> emails = [];
        if (techData is String && techData.isNotEmpty) {
          emails = techData.toLowerCase().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        } else if (techData is List) {
          emails = techData.map((e) => e.toString().toLowerCase()).toList();
        }

        // Augment with Google Event matching
        try {
          final googleEvent = googleEvents.firstWhere((e) => e['id'] == doc.id);
          
          // 1. Check attendees
          final attendees = googleEvent['attendees'] as List<dynamic>? ?? [];
          for (var attendee in attendees) {
            final email = attendee['email']?.toString().toLowerCase();
            if (email != null && email.isNotEmpty) {
              if (!emails.contains(email)) emails.add(email);
            }
          }
          
          // 2. Check description for tech emails
          final desc = googleEvent['description']?.toString().toLowerCase() ?? '';
          for (var tech in technicians) {
            final email = tech['email'].toString().toLowerCase();
            if (desc.contains(email) && !emails.contains(email)) {
              emails.add(email);
            }
          }
        } catch (_) {}
        
        // Pick first valid tech's color as main color
        Color techColor = Colors.grey;
        
        // Filter emails to ONLY include known technicians.
        // Syncfusion SfCalendar will hide the ENTIRE appointment if ANY resourceId is unknown.
        final validResourceIds = emails.where((email) {
          return technicians.any((t) => t['email'].toLowerCase() == email);
        }).toList();

        if (validResourceIds.isNotEmpty) {
          final tech = technicians.firstWhere(
            (t) => t['email'].toLowerCase() == validResourceIds.first,
            orElse: () => {'color': Colors.grey},
          );
          techColor = tech['color'] as Color? ?? Colors.grey;
        }

        try {
          final dynamic scheduledData = data['scheduled_time'] ?? data['visit_requested'];
          DateTime? scheduledTime;
          
          if (scheduledData is Timestamp) {
            scheduledTime = scheduledData.toDate();
          } else if (scheduledData is String && scheduledData.isNotEmpty) {
            scheduledTime = DateTime.tryParse(scheduledData);
          }
          
          if (scheduledTime == null) {
            final dynamic createdAt = data['created_at'];
            if (createdAt is Timestamp) {
              scheduledTime = createdAt.toDate().add(const Duration(days: 1));
            } else {
              scheduledTime = DateTime.now().add(const Duration(days: 1));
            }
            scheduledTime = DateTime(scheduledTime.year, scheduledTime.month, scheduledTime.day, 6, 30);
          } else if (scheduledTime.hour == 0 && scheduledTime.minute == 0) {
            // Default time to 6:30 AM if no time was provided (matches calendar.ts logic)
            scheduledTime = scheduledTime.add(const Duration(hours: 6, minutes: 30));
          }

          final dynamic endData = data['pm_notification_time'] ?? data['visit_end'];
          DateTime? endTime;
          if (endData is Timestamp) {
            endTime = endData.toDate();
          } else if (endData is String && endData.isNotEmpty) {
            endTime = DateTime.tryParse(endData);
          }

          if (scheduledTime != null) {
            final actualEndTime = endTime ?? scheduledTime.add(const Duration(hours: 3));
            return Appointment(
              id: doc.id,
              startTime: scheduledTime,
              endTime: actualEndTime,
              subject: data['property_address'] ?? 'Job',
              notes: 'Client: ${data['pm'] != null && data['pm'] is Map && data['pm']['company_name'] != null && data['pm']['company_name'].toString().isNotEmpty ? data['pm']['company_name'] : (data['client_name'] ?? '')}\nReq: ${data['visit_requested'] ?? ''}',
              color: validResourceIds.isNotEmpty ? techColor : Colors.limeAccent,
              resourceIds: validResourceIds.isNotEmpty ? validResourceIds : [assignGhostRow(scheduledTime, actualEndTime)],
              recurrenceRule: data['recurrence_rule'],
            );
          }
        } catch (e) {
          debugPrint('Error parsing appointment for lead ${doc.id}: $e');
        }
        // Return null if no valid appointment could be created
        return null;
      } catch (e) {
        debugPrint('Error mapping lead to appointment: $e');
        return null;
      }
    }).whereType<Appointment>().toList();

    // Extract known calendar event IDs from leads to prevent duplication
    final Set<String> knownCalendarIds = leads.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      return (data['calendar_event_id'] as String?) ?? '';
    }).where((id) => id.isNotEmpty).toSet();

    // Add Google Calendar Events
    final googleAppointments = googleEvents.map((event) {
      try {
        final eventId = event['id'] as String?;
        if (eventId != null && knownCalendarIds.contains(eventId)) {
          return null; // Skip events that are already in Firestore leads
        }

        // The backend `getTechCalendar` returns flat `start_time` and `end_time` even with raw=true
        final startStr = event['start_time'] ?? (event['start'] != null ? (event['start']['dateTime'] ?? event['start']['date']) : null);
        final endStr = event['end_time'] ?? (event['end'] != null ? (event['end']['dateTime'] ?? event['end']['date']) : null);
        
        var start = startStr != null ? DateTime.tryParse(startStr) : null;
        var end = endStr != null ? DateTime.tryParse(endStr) : null;

        if (start != null) {
          final summary = event['summary'] ?? 'Event';
          
          // Try to match attendee emails to resources
          List<String> resourceIds = [];
          if (event['attendees'] != null) {
            for (var attendee in event['attendees']) {
              final email = (attendee['email'] as String?)?.toLowerCase();
              if (email != null && technicians.any((t) => t['email'].toLowerCase() == email)) {
                resourceIds.add(email);
              }
            }
          }
          if (event['organizer'] != null) {
            final email = (event['organizer']['email'] as String?)?.toLowerCase();
            if (email != null && technicians.any((t) => t['email'].toLowerCase() == email) && !resourceIds.contains(email)) {
              resourceIds.add(email);
            }
          }
          if (event['creator'] != null) {
            final email = (event['creator']['email'] as String?)?.toLowerCase();
            if (email != null && technicians.any((t) => t['email'].toLowerCase() == email) && !resourceIds.contains(email)) {
              resourceIds.add(email);
            }
          }

          if (resourceIds.isEmpty) {
            // Clamp unassigned events to 8 AM and make them 3 hours long so the text is fully readable horizontally
            // Stagger them slightly based on a hash of the event ID so they cascade instead of perfectly overlapping
            int offsetMinutes = (event['id'].hashCode.abs() % 12) * 15; // 0, 15, 30... up to 165 mins offset
            start = DateTime(start.year, start.month, start.day, 8, offsetMinutes);
            end = start.add(const Duration(hours: 3));
            resourceIds.add(assignGhostRow(start, end!));
          }

          return Appointment(
            id: event['id'],
            startTime: start,
            endTime: end ?? start.add(const Duration(hours: 1)),
            subject: summary,
            notes: event['description'] ?? event['raw_description'] ?? '',
            color: resourceIds.isNotEmpty && !resourceIds.first.startsWith('unassigned_ghost') ? Colors.blueAccent : Colors.limeAccent, // fluorescent color for unassigned ghost events
            resourceIds: resourceIds,
          );
        }
      } catch (e) {
        debugPrint('Error mapping Google Event to appointment: $e');
      }
      return null;
    }).whereType<Appointment>().toList();

    appointments!.addAll(googleAppointments);

    resources = technicians.map((tech) {
      final email = (tech['email'] as String).toLowerCase();
      // Count jobs for this tech from the current leads list
      final jobCount = leads.where((doc) {
        final d = doc.data() as Map<String, dynamic>;
        final dynamic techData = d['technician_email'];
        List<String> emails = [];
        if (techData is String) {
          emails = techData.toLowerCase().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        } else if (techData is List) {
          emails = techData.map((e) => e.toString().toLowerCase()).toList();
        }
        return emails.contains(email);
      }).length;

      return CalendarResource(
        id: email,
        displayName: '${tech['name']} ($jobCount)',
        color: tech['color'],
      );
    }).toList();

    // Add the Unassigned Ghost resource rows in reverse order so ghost_0 is at top
    if (ghostRowCounter == 0) ghostRowCounter = 1; // Always show at least one
    for (int i = ghostRowCounter - 1; i >= 0; i--) {
      resources!.insert(0, CalendarResource(
        id: 'unassigned_ghost_$i',
        displayName: i == 0 ? 'Unassigned (Ghost)' : 'Unassigned',
        color: Colors.limeAccent.shade700,
      ));
    }
  }
}

class AssignLeadFromCalendarModal extends StatefulWidget {
  final DateTime selectedTime;
  final String techEmail;
  final List<Map<String, dynamic>> technicians;

  const AssignLeadFromCalendarModal({
    Key? key,
    required this.selectedTime,
    required this.techEmail,
    required this.technicians,
  }) : super(key: key);

  @override
  _AssignLeadFromCalendarModalState createState() => _AssignLeadFromCalendarModalState();
}

class _AssignLeadFromCalendarModalState extends State<AssignLeadFromCalendarModal> {
  String? _selectedLeadId;
  String? _additionalTechEmail;
  String? _additionalTechName;
  bool _isSaving = false;
  int _shiftDurationHours = 2;
  int _shiftDurationDays = 0;
  bool _skipWeekends = true;
  late DateTime _selectedTime;

  @override
  void initState() {
    super.initState();
    _selectedTime = widget.selectedTime;
  }

  void _handleSave() async {
    if (_selectedLeadId == null) return;
    setState(() => _isSaving = true);

    String techName = widget.techEmail;
    try {
      final tech = widget.technicians.firstWhere((t) => t['email'].toLowerCase() == widget.techEmail.toLowerCase());
      techName = tech['name'] ?? techName;
    } catch (_) {}

    final success = await FirebaseService().assignTech(
      leadId: _selectedLeadId!,
      techEmail: widget.techEmail,
      techName: techName,
      scheduledTime: _selectedTime,
    );

    String? recurrenceRule;
    if (_shiftDurationDays > 0) {
      if (_skipWeekends) {
        recurrenceRule = 'FREQ=DAILY;INTERVAL=1;COUNT=${_shiftDurationDays + 1};BYDAY=MO,TU,WE,TH,FR';
      } else {
        recurrenceRule = 'FREQ=DAILY;INTERVAL=1;COUNT=${_shiftDurationDays + 1}';
      }
    }

    await FirebaseService().rescheduleEvent(
      leadId: _selectedLeadId!,
      startTime: _selectedTime,
      endTime: _selectedTime.add(Duration(hours: _shiftDurationHours)),
      recurrenceRule: recurrenceRule,
    );
    
    bool success2 = true;
    if (_additionalTechEmail != null && _additionalTechName != null) {
      success2 = await FirebaseService().assignTech(
        leadId: _selectedLeadId!,
        techEmail: _additionalTechEmail!,
        techName: _additionalTechName!,
        scheduledTime: _selectedTime,
      );
    }

    setState(() => _isSaving = false);
    if (success && success2 && mounted) {
      Navigator.pop(context);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to assign lead.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Assign Unscheduled Lead'),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Assigning to: ${widget.techEmail}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            const Text('Start Time', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(_selectedTime),
                      );
                      if (time != null) {
                        setState(() {
                          _selectedTime = DateTime(
                            _selectedTime.year,
                            _selectedTime.month,
                            _selectedTime.day,
                            time.hour,
                            time.minute,
                          );
                        });
                      }
                    },
                    icon: const Icon(Icons.access_time),
                    label: Text(TimeOfDay.fromDateTime(_selectedTime).format(context)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Additional Tech (Optional)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_add),
              ),
              value: _additionalTechEmail,
              items: widget.technicians
                  .where((t) => t['email'].toLowerCase() != widget.techEmail.toLowerCase() && t['email'].toLowerCase() != 'info@idealmechanical.ca')
                  .map<DropdownMenuItem<String>>((tech) {
                final email = tech['email'] as String;
                return DropdownMenuItem<String>(
                  value: email,
                  child: Text('${tech['name']}'),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _additionalTechEmail = val;
                    _additionalTechName = widget.technicians.firstWhere((t) => t['email'] == val)['name'];
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Additional Days', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int>(
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.calendar_today),
                        ),
                        value: _shiftDurationDays,
                        items: [0, 1, 2, 3, 4, 5, 6, 7].map((days) {
                          return DropdownMenuItem<int>(
                            value: days,
                            child: Text(days == 0 ? 'Same Day' : '+$days Day(s)'),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) setState(() => _shiftDurationDays = val);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Shift Duration', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int>(
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.timer),
                        ),
                        value: _shiftDurationHours,
                        items: [2, 4, 6, 8, 10, 12, 24].map((hours) {
                          return DropdownMenuItem<int>(
                            value: hours,
                            child: Text('$hours Hours'),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _shiftDurationHours = val);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_shiftDurationDays > 0)
              CheckboxListTile(
                title: const Text('Skip Weekends'),
                subtitle: const Text('Only schedule on Mon-Fri'),
                value: _skipWeekends,
                onChanged: (val) {
                  if (val != null) setState(() => _skipWeekends = val);
                },
              ),
            const SizedBox(height: 32),
            const Text('Select an unassigned lead:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseService().getIntakeLeads(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                  final leads = snapshot.data?.docs ?? [];
                  if (leads.isEmpty) return const Center(child: Text('No unassigned leads available.'));
                  
                  return ListView.builder(
                    itemCount: leads.length,
                    itemBuilder: (context, index) {
                      final doc = leads[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final isSelected = _selectedLeadId == doc.id;
                      
                      return ListTile(
                        selected: isSelected,
                        selectedTileColor: Colors.orange.withOpacity(0.1),
                        title: Text(data['property_address'] ?? 'Unknown Address'),
                        subtitle: Text(data['pm'] != null && data['pm'] is Map && data['pm']['company_name'] != null && data['pm']['company_name'].toString().isNotEmpty ? data['pm']['company_name'] : (data['client_name'] ?? 'Unknown Client')),
                        onTap: () {
                          setState(() {
                            _selectedLeadId = doc.id;
                          });
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving || _selectedLeadId == null ? null : _handleSave,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
          child: _isSaving 
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('ASSIGN', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}




