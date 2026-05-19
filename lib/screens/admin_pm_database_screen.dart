import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/firebase_service.dart';

class AdminPMDatabaseScreen extends StatefulWidget {
  const AdminPMDatabaseScreen({super.key});

  @override
  State<AdminPMDatabaseScreen> createState() => _AdminPMDatabaseScreenState();
}

class _AdminPMDatabaseScreenState extends State<AdminPMDatabaseScreen> {
  final FirebaseService _firebaseService = FirebaseService();
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PM Database', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF3498DB),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search Project Managers...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: _searchQuery.isNotEmpty 
                  ? IconButton(
                      icon: const Icon(Icons.clear), 
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      }
                    ) 
                  : null,
              ),
              onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('pms').orderBy('full_name').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final pms = snapshot.data?.docs ?? [];
                final filteredPms = pms.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final name = (data['full_name'] ?? '').toString().toLowerCase();
                  final company = (data['company_name'] ?? '').toString().toLowerCase();
                  return name.contains(_searchQuery) || company.contains(_searchQuery);
                }).toList();

                if (filteredPms.isEmpty) {
                  return const Center(child: Text('No Project Managers found.'));
                }

                return ListView.builder(
                  itemCount: filteredPms.length,
                  itemBuilder: (context, index) {
                    final pm = filteredPms[index];
                    final data = pm.data() as Map<String, dynamic>;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue[100],
                        child: Text(data['full_name']?.toString().substring(0, 1).toUpperCase() ?? 'P'),
                      ),
                      title: Text(data['full_name'] ?? 'Unknown PM', style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(data['company_name'] ?? 'No Company'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_canDelete)
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _confirmDelete(context, pm.id, data['full_name']?.toString()),
                            ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => _showEditPMDialog(context, pm.id, data),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showEditPMDialog(BuildContext context, String pmId, Map<String, dynamic> data) {
    final nameController = TextEditingController(text: data['full_name']);
    final companyController = TextEditingController(text: data['company_name']);
    final emailController = TextEditingController(text: data['email']);
    final phoneController = TextEditingController(text: data['cell_phone']);
    final billingController = TextEditingController(text: data['billing_address']);
    final accountingEmailController = TextEditingController(text: data['billing_emails']);
    final assistantEmailController = TextEditingController(text: data['assistant_emails']);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit PM: ${data['full_name']}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Full Name')),
              TextField(controller: companyController, decoration: const InputDecoration(labelText: 'Company Name')),
              TextField(controller: emailController, decoration: const InputDecoration(labelText: 'Primary Email')),
              TextField(controller: phoneController, decoration: const InputDecoration(labelText: 'Cell Phone')),
              TextField(controller: accountingEmailController, decoration: const InputDecoration(labelText: 'Accounting / Billing Emails (comma separated)')),
              TextField(controller: assistantEmailController, decoration: const InputDecoration(labelText: 'PM Assistant Emails (comma separated)')),
              TextField(
                controller: billingController, 
                decoration: const InputDecoration(labelText: 'Billing Address'),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance.collection('pms').doc(pmId).update({
                'full_name': nameController.text,
                'company_name': companyController.text,
                'email': emailController.text,
                'cell_phone': phoneController.text,
                'billing_address': billingController.text,
                'billing_emails': accountingEmailController.text,
                'assistant_emails': assistantEmailController.text,
                'last_updated': FieldValue.serverTimestamp(),
              });
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('SAVE CHANGES'),
          ),
        ],
      ),
    );
  }

  bool get _canDelete {
    final email = FirebaseAuth.instance.currentUser?.email?.toLowerCase() ?? '';
    return email.startsWith('admin@') || email.startsWith('nicole@') || email.startsWith('tyler@');
  }

  void _confirmDelete(BuildContext context, String pmId, String? pmName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete PM?'),
        content: Text('Are you sure you want to delete ${pmName ?? 'this PM'}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await FirebaseFirestore.instance.collection('pms').doc(pmId).delete();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('DELETE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
