import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import '../services/firebase_service.dart';
import 'live_diagnostic_camera_screen.dart';
import '../widgets/diagnostic_chat_widget.dart';
import 'report_draft_screen.dart';
import '../ui/style/precision_theme.dart';
import 'ar_scanner_export.dart';

import 'package:firebase_auth/firebase_auth.dart';

class TechHomeScreen extends StatefulWidget {
  const TechHomeScreen({super.key});

  @override
  State<TechHomeScreen> createState() => _TechHomeScreenState();
}

class _TechHomeScreenState extends State<TechHomeScreen> {
  final FirebaseService _firebaseService = FirebaseService();
  String _selectedTechEmail = 'ALL';

  final List<Map<String, dynamic>> _technicians = [
    {'name': 'ALL SCHEDULES', 'email': 'ALL'},
    {'name': 'Berkant', 'email': 'berkant@immediateresponsehvac.ca'},
    {'name': 'Cory', 'email': 'cory@immediateresponsehvac.ca'},
    {'name': 'Deniz', 'email': 'deniz@immediateresponsehvac.ca'},
    {'name': 'Dominik', 'email': 'dominik@immediateresponsehvac.ca'},
    {'name': 'Evan', 'email': 'evan@immediateresponsehvac.ca'},
    {'name': 'HD HVAC', 'email': 'hdhvac@hotmail.com'},
    {'name': 'Hikmet', 'email': 'hikmet@immediateresponsehvac.ca'},
    {'name': 'Info', 'email': 'info@idealmechanical.ca'},
    {'name': 'Jordan', 'email': 'jordan@immediateresponsehvac.ca'},
    {'name': 'Jude', 'email': 'jude@immediateresponsehvac.ca'},
    {'name': 'Omar', 'email': 'omar@immediateresponsehvac.ca'},
    {'name': 'Randy', 'email': 'randy@immediateresponsehvac.ca'},
    {'name': 'Richard', 'email': 'richard@immediateresponsehvac.ca'},
    {'name': 'TDear', 'email': 'tdear@immediateresponsehvac.ca'},
  ];

  @override
  void initState() {
    super.initState();
    // Default to currently logged in tech (stored in displayName)
    final currentUserDisplayName = FirebaseAuth.instance.currentUser?.displayName;
    if (currentUserDisplayName != null && currentUserDisplayName.isNotEmpty) {
      final emailToCheck = currentUserDisplayName.toLowerCase();
      final match = _technicians.indexWhere((t) => t['email'] == emailToCheck);
      if (match != -1) {
        _selectedTechEmail = emailToCheck;
      } else {
        _technicians.add({'name': 'My Schedule', 'email': emailToCheck});
        _selectedTechEmail = emailToCheck;
      }
    } else {
      // Not logged in yet
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/tech/login');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: PrecisionTheme.background,
        appBar: AppBar(
          title: Text(
            'MY SCHEDULE', 
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: PrecisionTheme.pureWhite,
            ) ?? const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white)
          ),
          backgroundColor: PrecisionTheme.primaryCyan,
          foregroundColor: PrecisionTheme.pureWhite,
          elevation: 0,
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.mic),
              tooltip: 'Ask Tyler',
              onPressed: () => context.push('/tech/voice'),
            ),
            if (['tdear@immediateresponsehvac.ca', 'nicole@immediateresponsehvac.ca', 'cory@immediateresponsehvac.ca', 'admin@immediateresponsehvac.ca'].contains(FirebaseAuth.instance.currentUser?.displayName?.toLowerCase()))
              IconButton(
                icon: const Icon(Icons.admin_panel_settings),
                tooltip: 'Admin Dashboard',
                onPressed: () => context.go('/admin'),
              ),
          ],
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(48),
            child: TabBar(
              indicatorColor: PrecisionTheme.pureWhite,
              tabs: [
                Tab(text: 'TODO'),
                Tab(text: 'COMPLETED'),
              ],
              labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ),
        body: StreamBuilder<QuerySnapshot>(
          stream: _selectedTechEmail == 'ALL' 
            ? _firebaseService.getScheduledLeads() 
            : _firebaseService.getAssignedJobs(_selectedTechEmail),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final errStr = snapshot.error.toString();
              if (errStr.contains('permission-denied')) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.lock_outline, size: 64, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text('Authentication Required', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1E3A5F))),
                        const SizedBox(height: 8),
                        const Text('Please enable the "Anonymous" Sign-in provider in your Firebase Authentication console to allow the app to securely match leads.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                );
              }
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final allJobs = snapshot.data?.docs ?? [];
            if (allJobs.isEmpty) {
              return const Center(
                child: Text('No assigned jobs found.', style: TextStyle(color: Colors.grey)),
              );
            }

            final todoJobs = allJobs.where((j) {
              final status = (j.data() as Map)['status'];
              return status != 'report-submitted' && status != 'invoiced' && status != 'intake';
            }).toList();

            final completedJobs = allJobs.where((j) {
              final status = (j.data() as Map)['status'];
              return status == 'report-submitted' || status == 'invoiced';
            }).toList();

            return TabBarView(
              children: [
                _buildJobList(context, todoJobs),
                _buildJobList(context, completedJobs),
              ],
            );
          },
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'tech_home_voice_fab',
          onPressed: () {
            context.push('/tech/voice');
          },
          icon: const Icon(Icons.mic),
          label: const Text('Ask Tyler', style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: const Color(0xFFE67E22), // Vibrant orange
          foregroundColor: Colors.white,
          elevation: 8,
        ),
      ),
    );
  }

  Widget _buildJobList(BuildContext context, List<QueryDocumentSnapshot> jobs) {
    if (jobs.isEmpty) {
      return const Center(child: Text('No jobs in this category.', style: TextStyle(color: Colors.grey)));
    }

    final activeJobs = jobs.where((j) => (j.data() as Map)['status'] == 'in-progress').toList();
    final upcomingJobs = jobs.where((j) => (j.data() as Map)['status'] == 'scheduled' || (j.data() as Map)['status'] == 'assigned').toList();
    final finishedJobs = jobs.where((j) {
       final status = (j.data() as Map)['status'];
       return status == 'report-submitted' || status == 'invoiced';
    }).toList();

    final nextJob = activeJobs.isNotEmpty ? activeJobs.first : (upcomingJobs.isNotEmpty ? upcomingJobs.first : null);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (nextJob != null && finishedJobs.isEmpty) ...[
          const Text('NEXT JOB', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.2, color: Color(0xFF3498DB))),
          const SizedBox(height: 8),
          _NextJobCard(job: nextJob),
          const SizedBox(height: 24),
        ],
        ...finishedJobs.map((job) => _UpcomingJobTile(job: job)),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: () => _showManualInspectionModal(context),
          icon: const Icon(Icons.add, color: Colors.black),
          label: const Text('START MANUAL INSPECTION', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Colors.black)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFA5D9F3), // IMR Sky Blue
            minimumSize: const Size(double.infinity, 56),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        const SizedBox(height: 48),
      ],
    );
  }

  void _showManualInspectionModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => _ManualInspectionForm(),
    );
  }
}

class _ManualInspectionForm extends StatefulWidget {
  @override
  State<_ManualInspectionForm> createState() => _ManualInspectionFormState();
}

class _ManualInspectionFormState extends State<_ManualInspectionForm> {
  final TextEditingController _addressController = TextEditingController();
  
  String? _selectedReportType;
  final List<String> _reportTypes = [
    'Inspection Report',
    'Troubleshooting Report',
    'Progress Report',
    'Post Job Report',
    'Quote Report',
    'DC Report',
    'Service Report'
  ];

  List<dynamic> _suggestions = [];
  bool _isSearching = false;

  Future<void> _searchAddress(String query) async {
    if (query.length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    setState(() => _isSearching = true);
    // Note: In production, call a secure backend function to proxy Google Places API
    // For this prototype, we call a dedicated 'autocompleteAddress' function
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('autocompleteAddress');
      final result = await callable.call({'query': query});
      if (mounted) {
        setState(() {
          _suggestions = result.data['predictions'] ?? [];
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const skyBlue = Color(0xFFA5D9F3);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 24,
        right: 24,
        top: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MANUAL INSPECTION', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: skyBlue)),
          const SizedBox(height: 24),
          const Text('SEARCH PROPERTY ADDRESS', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: _addressController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter address...',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              prefixIcon: const Icon(Icons.search, color: skyBlue),
              filled: true,
              fillColor: const Color(0xFF131313),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
              focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: skyBlue, width: 2)),
            ),
            onChanged: _searchAddress,
          ),
          if (_isSearching) const LinearProgressIndicator(backgroundColor: Colors.transparent, valueColor: AlwaysStoppedAnimation(skyBlue)),
          if (_suggestions.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                itemCount: _suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = _suggestions[index];
                  return ListTile(
                    title: Text(suggestion['description'], style: const TextStyle(color: Colors.white)),
                    onTap: () {
                      setState(() {
                        _addressController.text = suggestion['description'];
                        _suggestions = [];
                      });
                    },
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
          const Text('REPORT TYPE', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _selectedReportType,
            dropdownColor: const Color(0xFF131313),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Select Report Type',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              filled: true,
              fillColor: const Color(0xFF131313),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
              focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: skyBlue, width: 2)),
            ),
            items: _reportTypes.map((type) => DropdownMenuItem(value: type, child: Text(type))).toList(),
            onChanged: (val) => setState(() => _selectedReportType = val),
          ),

          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () async {
              final address = _addressController.text.trim();
              
              if (address.isEmpty || _selectedReportType == null) return;
              
              final projectName = '$address - $_selectedReportType';
              
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                backgroundColor: skyBlue,
                content: Text('INITIALIZING FORENSIC FOLDER: $projectName', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ));
              
              // Call manualIntake service
              try {
                await FirebaseService().manualIntake(
                  propertyAddress: address, 
                  claimRef: projectName,
                  technicianEmail: FirebaseAuth.instance.currentUser?.email ?? '',
                );

                if (mounted) {
                  Navigator.of(context).pop(); // Close modal
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Forensic Project created!'),
                      backgroundColor: Colors.green,
                    )
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red,
                    )
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: skyBlue,
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('CREATE FORENSIC PROJECT', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black, letterSpacing: 1.2)),
          ),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

class _NextJobCard extends StatefulWidget {
  final QueryDocumentSnapshot job;
  const _NextJobCard({required this.job});

  @override
  State<_NextJobCard> createState() => _NextJobCardState();
}

class _NextJobCardState extends State<_NextJobCard> {
  bool _isStarting = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.job.data() as Map<String, dynamic>;
    final address = data['property_address'] ?? 'No Address';
    final client = data['client_name'] ?? 'Unknown';
    final status = data['status'] ?? 'scheduled';
    final activeTimer = data['active_timer'] as Map<String, dynamic>?;
    final isDriving = status == 'in-progress' && activeTimer?['type'] == 'drive';
    final isAtSite = status == 'in-progress' && activeTimer?['type'] == 'labor';

    // Calculate Time Since Dispatch
    final dynamic assignedAt = data['assigned_at'] ?? data['created_at'];
    String timeSinceDispatch = 'Just now';
    if (assignedAt is Timestamp) {
      final diff = DateTime.now().difference(assignedAt.toDate());
      timeSinceDispatch = diff.inHours > 0 ? '${diff.inHours}h ${diff.inMinutes % 60}m ago' : '${diff.inMinutes}m ago';
    } else if (assignedAt is String) {
      final date = DateTime.tryParse(assignedAt);
      if (date != null) {
        final diff = DateTime.now().difference(date);
        timeSinceDispatch = diff.inHours > 0 ? '${diff.inHours}h ${diff.inMinutes % 60}m ago' : '${diff.inMinutes}m ago';
      }
    }

    final emergencyDispatch = data['emergency_dispatch'] == true;
    final urgencyLevel = emergencyDispatch ? 'URGENT (CODE RED)' : 'STANDARD';

    final jobCategories = (data['job_categories'] as List<dynamic>?)?.cast<String>() ?? [];
    final isHeating = jobCategories.any((cat) => cat.toLowerCase().contains('furnace') || cat.toLowerCase().contains('boiler') || cat.toLowerCase().contains('fire'));
    
    // Command Center Aesthetics
    final accentColor = isHeating ? Colors.white : const Color(0xFF00E5FF);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF050505), // Intense Command Center Black
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: accentColor.withOpacity(0.15), blurRadius: 30, offset: const Offset(0, 10)),
        ],
        border: Border.all(
          color: isDriving 
              ? Colors.blue.withOpacity(0.8) 
              : (isAtSite ? const Color(0xFFE67E22).withOpacity(0.8) : accentColor.withOpacity(0.4)), 
          width: 2
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Urgency & Dispatch Time Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: emergencyDispatch ? Colors.red.withOpacity(0.2) : accentColor.withOpacity(0.1),
                  border: Border.all(color: emergencyDispatch ? Colors.red : accentColor.withOpacity(0.5)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(emergencyDispatch ? Icons.warning_amber_rounded : Icons.info_outline, 
                         color: emergencyDispatch ? Colors.redAccent : accentColor, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      urgencyLevel,
                      style: TextStyle(
                        color: emergencyDispatch ? Colors.redAccent : accentColor, 
                        fontWeight: FontWeight.w900, 
                        fontSize: 10, 
                        letterSpacing: 1.5
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Icon(Icons.timer_outlined, color: Colors.grey[500], size: 14),
                  const SizedBox(width: 4),
                  Text(
                    timeSinceDispatch.toUpperCase(),
                    style: TextStyle(color: Colors.grey[400], fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          Row(
            children: [
              CircleAvatar(
                backgroundColor: accentColor.withOpacity(0.1),
                child: Icon(Icons.home_work, color: accentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(address, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
                    Text(client, style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // View Job Details Button (Always accessible)
          OutlinedButton.icon(
            onPressed: () => showJobDetailsBottomSheet(context, data, widget.job.id),
            icon: const Icon(Icons.description_outlined),
            label: const Text('VIEW JOB DETAILS', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            style: OutlinedButton.styleFrom(
              foregroundColor: accentColor,
              side: BorderSide(color: accentColor.withOpacity(0.4), width: 1.5),
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 16),
          if (status == 'assigned' || status == 'scheduled')
            ElevatedButton.icon(
              onPressed: _isStarting ? null : () => _startNavigation(context),
              icon: _isStarting 
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.near_me, color: Colors.black),
              label: const Text('START DRIVING TO JOB', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Colors.black)),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                minimumSize: const Size(double.infinity, 56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            )
          else if (isDriving)
            Column(
              children: [
                ElevatedButton.icon(
                  onPressed: _isStarting ? null : () => _clockIn(context),
                  icon: _isStarting 
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.location_on),
                  label: const Text('ARRIVED (CLOCK IN)', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent[700],
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => _openMap(address),
                  icon: const Icon(Icons.map, color: Colors.white),
                  label: const Text('RESUME NAVIGATION', style: TextStyle(color: Colors.white)),
                ),
              ],
            )
          else if (isAtSite)
            ElevatedButton.icon(
              onPressed: () => _openReport(context),
              icon: const Icon(Icons.assignment_outlined, color: Colors.black),
              label: const Text('CONTINUE TO REPORT', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Colors.black)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE67E22), // Warning orange
                minimumSize: const Size(double.infinity, 56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _startNavigation(BuildContext context) async {
    setState(() => _isStarting = true);
    
    final navUrl = await FirebaseService().startNavigation(widget.job.id);
    
    setState(() => _isStarting = false);
    
    if (navUrl != null) {
      final uri = Uri.parse(navUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to start navigation. Check connectivity.')));
      }
    }
  }

  Future<void> _clockIn(BuildContext context) async {
    setState(() => _isStarting = true);
    try {
      final position = await Geolocator.getCurrentPosition();
      final success = await FirebaseService().techClockIn(
        widget.job.id,
        position.latitude,
        position.longitude,
      );
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clock-in failed. Are you at the site?')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error getting location for clock-in.')));
      }
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  Future<void> _openMap(String address) async {
    final url = 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openReport(BuildContext context) {
    context.push('/job/${widget.job.id}');
  }
}

class _UpcomingJobTile extends StatelessWidget {
  final QueryDocumentSnapshot job;
  const _UpcomingJobTile({required this.job});

  @override
  Widget build(BuildContext context) {
    final data = job.data() as Map<String, dynamic>;
    final address = data['property_address'] ?? 'No Address';
    final client = data['client_name'] ?? 'Unknown';
    final dynamic scheduledData = data['scheduled_time'];
    DateTime? scheduledTime;
    
    if (scheduledData is Timestamp) {
      scheduledTime = scheduledData.toDate();
    } else if (scheduledData is String) {
      String s = scheduledData;
      if (s.length > 19 && (s[19] == '+' || s[19] == '-')) {
        s = s.substring(0, 19);
      } else if (s.endsWith('Z')) {
        final dt = DateTime.tryParse(s);
        if (dt != null) s = dt.subtract(const Duration(hours: 4)).toIso8601String().substring(0, 19);
      }
      scheduledTime = DateTime.tryParse(s);
    }

    final accentColor = const Color(0xFF00E5FF);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF050505),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.15), width: 1.5),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showJobDetailsBottomSheet(context, data, job.id),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.1), 
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: accentColor.withOpacity(0.3)),
                      ),
                      child: Column(
                        children: [
                          Text(
                            scheduledTime != null ? DateFormat('MMM').format(scheduledTime).toUpperCase() : '??',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: accentColor, letterSpacing: 1),
                          ),
                          Text(
                            scheduledTime != null ? DateFormat('dd').format(scheduledTime) : '??',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(address, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
                          const SizedBox(height: 4),
                          Text(
                            scheduledTime != null ? DateFormat('jm').format(scheduledTime) : 'Pending Date/Time',
                            style: TextStyle(color: Colors.grey[400], fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          Text(client, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: accentColor.withOpacity(0.8)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void showJobDetailsBottomSheet(BuildContext context, Map<String, dynamic> data, String jobId) {
  final accentColor = const Color(0xFF00E5FF);
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF131313),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (context) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          final pmName = (data['pm'] is Map) ? data['pm']['full_name'] : 'None';
          final categories = (data['job_categories'] as List<dynamic>?)?.cast<String>() ?? [];
          final address = data['property_address'] ?? 'N/A';
          
          final dynamic scheduledData = data['scheduled_time'];
          DateTime? scheduledTime;
          if (scheduledData is Timestamp) {
            scheduledTime = scheduledData.toDate();
          } else if (scheduledData is String) {
            String s = scheduledData;
            if (s.length > 19 && (s[19] == '+' || s[19] == '-')) {
              s = s.substring(0, 19);
            } else if (s.endsWith('Z')) {
              final dt = DateTime.tryParse(s);
              if (dt != null) s = dt.subtract(const Duration(hours: 4)).toIso8601String().substring(0, 19);
            }
            scheduledTime = DateTime.tryParse(s);
          }
          String scheduleStr = 'Pending Date/Time';
          if (scheduledTime != null) {
            // Displaying standard 1 hour duration block
            final endTime = scheduledTime.add(const Duration(hours: 1));
            scheduleStr = '${DateFormat('MMM d, y').format(scheduledTime)} • ${DateFormat('jm').format(scheduledTime)} - ${DateFormat('jm').format(endTime)}';
          }
          
          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: ListView(
              controller: scrollController,
              children: [
                const Text('JOB DETAILS', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF00E5FF))),
                const SizedBox(height: 24),
                
                // Action rows for Navigation, Diagnostics, AI, and Reporting
                Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final url = 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}';
                              final uri = Uri.parse(url);
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri, mode: LaunchMode.externalApplication);
                              }
                            },
                            icon: const Icon(Icons.near_me, color: Colors.black, size: 16),
                            label: const Text('DRIVE TO JOB', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: accentColor,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop(); // Close sheet
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => LiveDiagnosticCameraScreen(
                                    jobId: jobId,
                                    propertyAddress: address,
                                    jobType: data['job_type'] ?? 'Unknown',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                            label: const Text('DIAGNOSTICS', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE67E22), // Standout orange
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop(); // Close sheet
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => ReportDraftScreen(
                                    leadId: jobId,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.description_outlined, color: Colors.white, size: 16),
                            label: const Text('CREATE REPORT', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green, // Differentiate Report
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop(); // Close sheet
                              context.push('/tech/voice?leadId=$jobId');
                            },
                            icon: const Icon(Icons.smart_toy, color: Colors.white, size: 16),
                            label: const Text('ASK TYLER', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.white, fontSize: 13)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF9B59B6), // Purple indicator for Tyler AI
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop(); // Close sheet
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => ARScannerScreen(
                                    leadId: jobId,
                                    scanId: 'scan_${DateTime.now().millisecondsSinceEpoch}',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.view_in_ar, color: Colors.white, size: 16),
                            label: const Text('START LiDAR INSPECTION', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF3498DB), // Blue
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                _buildDetailRow('Scheduled', scheduleStr),
                _buildDetailRow('Address', address),
                _buildDetailRow('Client', data['client_name'] ?? 'N/A'),
                _buildDetailRow('Phone', data['client_cell'] ?? 'N/A'),
                _buildDetailRow('Job Type', data['job_type'] ?? 'N/A'),
                if (data['claim_type'] != null) _buildDetailRow('Claim Type', data['claim_type']),
                if (pmName != 'None') _buildDetailRow('Project Manager', pmName),
                _buildDetailRow('Categories', categories.join(', ').isEmpty ? 'N/A' : categories.join(', ')),
                _buildDetailRow('Access', data['access_instructions'] ?? 'N/A'),
                const SizedBox(height: 20),
                const Text('SCOPE OF WORK', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.withOpacity(0.2)),
                  ),
                  child: Text(
                    data['scope_details'] ?? 'No scope provided.', 
                    style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5)
                  ),
                ),
                const SizedBox(height: 48),
              ],
            ),
          );
        },
      );
    },
  );
}

Widget _buildDetailRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 16.0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 130, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1))),
        Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white, fontSize: 16))),
      ],
    ),
  );
}
