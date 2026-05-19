import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

class TechLoginScreen extends StatefulWidget {
  const TechLoginScreen({super.key});

  @override
  State<TechLoginScreen> createState() => _TechLoginScreenState();
}

class _TechLoginScreenState extends State<TechLoginScreen> {
  final List<Map<String, String>> _technicians = [
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
    {'name': 'Leam Hamilton', 'email': 'leamhamilton1973@gmail.com'},
    {'name': 'Nicole', 'email': 'nicole@immediateresponsehvac.ca'},
    {'name': 'Omar', 'email': 'omar@immediateresponsehvac.ca'},
    {'name': 'Randy', 'email': 'randy@immediateresponsehvac.ca'},
    {'name': 'Richard', 'email': 'richard@immediateresponsehvac.ca'},
    {'name': 'TDear', 'email': 'tdear@immediateresponsehvac.ca'},
    {'name': 'William Hamilton', 'email': 'whamilton10@hotmail.com'},
    {'name': 'Admin', 'email': 'admin@immediateresponsehvac.ca'},
  ];
  String? _selectedTechEmail;
  bool _isLoading = false;

  void _login() async {
    if (_selectedTechEmail == null) return;
    setState(() => _isLoading = true);
    
    try {
      final auth = FirebaseAuth.instance;
      if (auth.currentUser == null) {
        await auth.signInAnonymously();
      }
      
      // Save tech email to displayName for easy retrieval without complex Custom Claims/DB queries for now
      await auth.currentUser?.updateDisplayName(_selectedTechEmail);
      
      if (mounted) {
        final adminEmails = [
          'tdear@immediateresponsehvac.ca',
          'nicole@immediateresponsehvac.ca',
          'cory@immediateresponsehvac.ca',
          'admin@immediateresponsehvac.ca',
        ];
        if (adminEmails.contains(_selectedTechEmail?.toLowerCase())) {
          context.go('/dispatch');
        } else {
          context.go('/tech');
        }
      }
    } catch (e) {
      debugPrint('Login error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1C),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: const Color(0xFF141B2D),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00E5FF).withOpacity(0.1),
                blurRadius: 30,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.admin_panel_settings,
                size: 64,
                color: Color(0xFF00E5FF),
              ),
              const SizedBox(height: 24),
              const Text(
                'IRHVAC COMMAND CENTER',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'TECHNICIAN LOGIN',
                style: TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 48),
              DropdownButtonFormField<String>(
                value: _selectedTechEmail,
                dropdownColor: const Color(0xFF1E293B),
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'Select Profile',
                  labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF334155)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF00E5FF)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0A0F1C),
                  prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF94A3B8)),
                ),
                items: _technicians.map((tech) {
                  return DropdownMenuItem(
                    value: tech['email'],
                    child: SizedBox(
                      width: 250, // Constrain the width
                      child: Text(
                        '${tech['name']} (${tech['email']})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() => _selectedTechEmail = val);
                },
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading || _selectedTechEmail == null ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: const Color(0xFF0A0F1C),
                    disabledBackgroundColor: const Color(0xFF334155),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0A0F1C)),
                          ),
                        )
                      : const Text(
                          'ACCESS DASHBOARD',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
