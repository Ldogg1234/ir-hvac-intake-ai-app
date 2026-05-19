import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

class AdminIntakeScreen extends StatefulWidget {
  const AdminIntakeScreen({super.key});

  @override
  State<AdminIntakeScreen> createState() => _AdminIntakeScreenState();
}

class _AdminIntakeScreenState extends State<AdminIntakeScreen> {
  final _formKey = GlobalKey<FormState>();

  // Job Info
  String? _jobType;
  String? _claimType;
  String? _workRequested;
  
  // Inspection sub-items
  final Set<String> _inspectionItems = {};
  String? _equipmentType;
  String? _fuelType;
  String? _applianceCount;
  String? _applianceList;
  String? _miscDescription;

  // Property Info
  final _propertyAddressController = TextEditingController();
  final _apartmentNumberController = TextEditingController();

  // Property Owner Info
  final _clientNameController = TextEditingController();
  final _clientEmailController = TextEditingController();
  final _clientPhoneController = TextEditingController();

  // PM Info
  final _pmNameController = TextEditingController();
  final _pmCompanyController = TextEditingController();
  final _pmEmailController = TextEditingController();
  final _pmPhoneController = TextEditingController();
  final _pmBillingAddressController = TextEditingController();
  final _pmAssistantEmailsController = TextEditingController();
  final _pmBillingEmailsController = TextEditingController();
  bool _updatePmRecord = false;
  String? _selectedPmId;

  // Visit Details
  String? _visitStatus;
  DateTime? _visitRequestedStart;
  DateTime? _visitRequestedEnd;
  String? _accessInstructions;
  final _lockboxCodeController = TextEditingController();
  final _poNumberController = TextEditingController();
  String _emergencyDispatch = 'No';
  final _scopeDetailsController = TextEditingController();

  // Supporting Documents
  final List<PlatformFile> _supportingDocs = [];

  bool _isSaving = false;
  
  // Fake PM data for now. We will replace with real Firestore data soon
  List<Map<String, dynamic>> _pmCache = [];

  @override
  void initState() {
    super.initState();
    _loadPms();
    
    final now = DateTime.now();
    _visitRequestedStart = DateTime(now.year, now.month, now.day + 1, 9, 0);
  }
  
  Future<void> _loadPms() async {
    try {
      final snapshot = await FirebaseFirestore.instance.collection('pms').get();
      setState(() {
        _pmCache = snapshot.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      });
    } catch (e) {
      debugPrint('Failed to load PMs: $e');
    }
  }

  bool get _isInsurance => _jobType == 'Res_Insurance' || _jobType == 'Comm_Insurance';
  bool get _isInspection => _workRequested == 'Inspection';
  bool get _isMisc => _workRequested == 'Troubleshooting' || _workRequested == 'Repairs and Replacement';
  bool get _showEquipmentLogic => _inspectionItems.contains('Furnace') || _inspectionItems.contains('HWT');
  bool get _showAppliancesLogic => _inspectionItems.contains('Appliances');
  bool get _isConfirmedVisit => _visitStatus == 'Confirmed date';
  bool get _isLockbox => _accessInstructions == 'Lockbox';

  @override
  void dispose() {
    _propertyAddressController.dispose();
    _apartmentNumberController.dispose();
    _clientNameController.dispose();
    _clientEmailController.dispose();
    _clientPhoneController.dispose();
    _pmNameController.dispose();
    _pmCompanyController.dispose();
    _pmEmailController.dispose();
    _pmPhoneController.dispose();
    _pmBillingAddressController.dispose();
    _pmAssistantEmailsController.dispose();
    _pmBillingEmailsController.dispose();
    _lockboxCodeController.dispose();
    _poNumberController.dispose();
    _scopeDetailsController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx'],
        withData: true,
      );
      if (result != null) {
        setState(() => _supportingDocs.addAll(result.files));
      }
    } catch (e) {
      debugPrint('Error picking files: $e');
    }
  }

  void _removeFile(int index) {
    setState(() => _supportingDocs.removeAt(index));
  }

  void _submitForm() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in first'), backgroundColor: Colors.red),
      );
      return;
    }
    
    setState(() => _isSaving = true);
    
    try {
      final token = await user.getIdToken();
      
      final combinedCategories = [
        _workRequested!,
        ..._inspectionItems
      ];

      final leadData = {
        'property_address': _propertyAddressController.text,
        'apartment_number': _apartmentNumberController.text.isNotEmpty ? _apartmentNumberController.text : null,
        'job_type': _jobType,
        'claim_type': _claimType,
        'job_categories': combinedCategories,
        'misc_description': _miscDescription,
        'client_name': _clientNameController.text,
        'client_email': _clientEmailController.text.isNotEmpty ? _clientEmailController.text : null,
        'client_cell': _clientPhoneController.text.isNotEmpty ? _clientPhoneController.text : null,
        'scope_details': _scopeDetailsController.text.isNotEmpty ? _scopeDetailsController.text : null,
        'po_number': _poNumberController.text.isNotEmpty ? _poNumberController.text : null,
        'visit_requested': _visitRequestedStart?.toIso8601String(),
        'visit_end': _visitRequestedEnd?.toIso8601String(),
        'visit_status': _visitStatus,
        'access_instructions': _accessInstructions,
        'lockbox_code': _lockboxCodeController.text.isNotEmpty ? _lockboxCodeController.text : null,
        'emergency_dispatch': _emergencyDispatch == 'Yes',
        'appliance_count': _applianceCount,
        'appliance_list': _applianceList,
        'equipment_type': _equipmentType,
        'fuel_type': _fuelType,
        'update_pm': _updatePmRecord,
      };

      if (_supportingDocs.isNotEmpty) {
        leadData['supporting_docs'] = _supportingDocs.map((f) {
           return {
             'name': f.name,
             'data': base64Encode(f.bytes!),
             'mime_type': f.extension == 'pdf' ? 'application/pdf' : 'application/msword',
           };
        }).toList();
      }

      if (_isInsurance) {
        leadData['pm'] = {
          'full_name': _pmNameController.text,
          'company_name': _pmCompanyController.text.isNotEmpty ? _pmCompanyController.text : null,
          'email': _pmEmailController.text.isNotEmpty ? _pmEmailController.text : null,
          'cell_phone': _pmPhoneController.text.isNotEmpty ? _pmPhoneController.text : null,
          'billing_address': _pmBillingAddressController.text.isNotEmpty ? _pmBillingAddressController.text : null,
          'assistant_emails': _pmAssistantEmailsController.text.isNotEmpty ? _pmAssistantEmailsController.text : null,
          'billing_emails': _pmBillingEmailsController.text.isNotEmpty ? _pmBillingEmailsController.text : null,
        };
      }

      final response = await http.post(
        Uri.parse('https://intake-406471533341.us-central1.run.app'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(leadData),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Lead submitted successfully!'), backgroundColor: Colors.green),
          );
          GoRouter.of(context).pop();
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Submission failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Lead Intake', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _isSaving
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSectionHeader('Job Information'),
                    _buildJobInfo(),
                    
                    const SizedBox(height: 24),
                    _buildSectionHeader('Property Information'),
                    _buildPropertyInfo(),
                    
                    const SizedBox(height: 24),
                    _buildSectionHeader('Property Owner Information'),
                    _buildOwnerInfo(),
                    
                    if (_isInsurance) ...[
                      const SizedBox(height: 24),
                      _buildSectionHeader('Project Manager Information'),
                      _buildPmInfo(),
                    ],
                    
                    const SizedBox(height: 24),
                    _buildSectionHeader('Visit Details'),
                    _buildVisitDetails(),
                    
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _submitForm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF4A261),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('SUBMIT LEAD', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Container(width: 4, height: 20, decoration: BoxDecoration(color: const Color(0xFFF4A261), borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E3A5F))),
        ],
      ),
    );
  }

  Widget _buildJobInfo() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Job Type *', border: OutlineInputBorder()),
              value: _jobType,
              items: const [
                DropdownMenuItem(value: 'Res_Insurance', child: Text('Residential Insurance')),
                DropdownMenuItem(value: 'Comm_Insurance', child: Text('Commercial Insurance')),
                DropdownMenuItem(value: 'Residential', child: Text('Residential')),
                DropdownMenuItem(value: 'Commercial', child: Text('Commercial')),
              ],
              onChanged: (v) {
                setState(() {
                  _jobType = v;
                  if (!_isInsurance) {
                    _claimType = null;
                  }
                });
              },
              validator: (v) => v == null ? 'Required' : null,
            ),
            if (_isInsurance) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Claim Type *', border: OutlineInputBorder()),
                value: _claimType,
                items: const [
                  DropdownMenuItem(value: 'Flood', child: Text('Flood')),
                  DropdownMenuItem(value: 'Fire', child: Text('Fire')),
                  DropdownMenuItem(value: 'Abatement', child: Text('Abatement')),
                  DropdownMenuItem(value: 'Other', child: Text('Other')),
                ],
                onChanged: (v) => setState(() => _claimType = v),
                validator: (v) => _isInsurance && v == null ? 'Required' : null,
              ),
            ],
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Work Requested *', border: OutlineInputBorder()),
              value: _workRequested,
              items: const [
                DropdownMenuItem(value: 'Inspection', child: Text('Inspection')),
                DropdownMenuItem(value: 'Troubleshooting', child: Text('Troubleshooting')),
                DropdownMenuItem(value: 'Repairs and Replacement', child: Text('Repairs and Replacement')),
              ],
              onChanged: (v) {
                setState(() {
                  _workRequested = v;
                  if (!_isInspection) {
                    _inspectionItems.clear();
                  }
                });
              },
              validator: (v) => v == null ? 'Required' : null,
            ),
            if (_isInspection) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFFF0F7FF), border: Border.all(color: Colors.blue.withOpacity(0.3)), borderRadius: BorderRadius.circular(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Inspection Details', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: ['Furnace', 'HWT', 'HRV', 'Ducts', 'Venting/Flue', 'AC', 'Heat Pump', 'Appliances'].map((item) {
                        return FilterChip(
                          label: Text(item),
                          selected: _inspectionItems.contains(item),
                          onSelected: (selected) {
                            setState(() {
                              selected ? _inspectionItems.add(item) : _inspectionItems.remove(item);
                            });
                          },
                        );
                      }).toList(),
                    ),
                    if (_showEquipmentLogic) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              decoration: const InputDecoration(labelText: 'Equipment Type', border: OutlineInputBorder()),
                              value: _equipmentType,
                              items: const [
                                DropdownMenuItem(value: 'Gas', child: Text('Gas')),
                                DropdownMenuItem(value: 'Oil', child: Text('Oil')),
                                DropdownMenuItem(value: 'Electric', child: Text('Electric')),
                                DropdownMenuItem(value: 'Boiler', child: Text('Boiler')),
                              ],
                              onChanged: (v) => setState(() => _equipmentType = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              decoration: const InputDecoration(labelText: 'Fuel Type', border: OutlineInputBorder()),
                              value: _fuelType,
                              items: const [
                                DropdownMenuItem(value: 'Natural Gas', child: Text('Natural Gas')),
                                DropdownMenuItem(value: 'Propane', child: Text('Propane')),
                              ],
                              onChanged: (v) => setState(() => _fuelType = v),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_showAppliancesLogic) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: TextFormField(
                              decoration: const InputDecoration(labelText: 'Count', border: OutlineInputBorder()),
                              onChanged: (v) => _applianceCount = v,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              decoration: const InputDecoration(labelText: 'List Appliances', border: OutlineInputBorder()),
                              onChanged: (v) => _applianceList = v,
                            ),
                          ),
                        ],
                      )
                    ]
                  ],
                ),
              ),
            ],
            if (_isMisc) ...[
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Description *', border: OutlineInputBorder(), hintText: 'Provide details about troubleshooting or repairs...'),
                onChanged: (v) => _miscDescription = v,
                validator: (v) => _isMisc && (v == null || v.isEmpty) ? 'Required' : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPropertyInfo() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Autocomplete<Map<String, dynamic>>(
              displayStringForOption: (option) => option['description'] ?? '',
              optionsBuilder: (textEditingValue) async {
                if (textEditingValue.text.length < 3) {
                  return const Iterable<Map<String, dynamic>>.empty();
                }
                try {
                  final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('autocompleteAddress');
                  final result = await callable.call({'query': textEditingValue.text});
                  final List<dynamic> predictions = result.data['predictions'] ?? [];
                  return predictions.map((e) => Map<String, dynamic>.from(e as Map));
                } catch (e) {
                  debugPrint('Autocomplete error: $e');
                  return const Iterable<Map<String, dynamic>>.empty();
                }
              },
              onSelected: (selection) {
                setState(() {
                  _propertyAddressController.text = selection['description'] ?? '';
                });
              },
              fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                if (_propertyAddressController.text.isNotEmpty && textEditingController.text.isEmpty) {
                  textEditingController.text = _propertyAddressController.text;
                }
                return TextFormField(
                  controller: textEditingController,
                  focusNode: focusNode,
                  decoration: const InputDecoration(labelText: 'Property Address *', border: OutlineInputBorder()),
                  validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                  onChanged: (v) => setState(() => _propertyAddressController.text = v),
                );
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apartmentNumberController,
              decoration: const InputDecoration(labelText: 'Apartment / Unit Number', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOwnerInfo() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextFormField(
              controller: _clientNameController,
              decoration: const InputDecoration(labelText: 'Property Owner Name *', border: OutlineInputBorder()),
              validator: (v) => v == null || v.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _clientEmailController,
              decoration: const InputDecoration(labelText: 'Property Owner Email', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _clientPhoneController,
              decoration: const InputDecoration(labelText: 'Property Owner Phone', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPmInfo() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Autocomplete<Map<String, dynamic>>(
              displayStringForOption: (option) => option['full_name'] ?? '',
              optionsBuilder: (textEditingValue) {
                if (textEditingValue.text.isEmpty) {
                  return const Iterable<Map<String, dynamic>>.empty();
                }
                final query = textEditingValue.text.toLowerCase();
                return _pmCache.where((pm) {
                  final name = (pm['full_name'] ?? '').toLowerCase();
                  final company = (pm['company_name'] ?? '').toLowerCase();
                  return name.contains(query) || company.contains(query);
                });
              },
              onSelected: (selection) {
                setState(() {
                  _selectedPmId = selection['id'];
                  _pmNameController.text = selection['full_name'] ?? '';
                  _pmCompanyController.text = selection['company_name'] ?? '';
                  _pmEmailController.text = selection['email'] ?? '';
                  _pmPhoneController.text = selection['cell_phone'] ?? '';
                  _pmBillingAddressController.text = selection['billing_address'] ?? '';
                  _pmAssistantEmailsController.text = selection['assistant_emails'] ?? '';
                  _pmBillingEmailsController.text = selection['billing_emails'] ?? '';
                });
              },
              fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                if (_pmNameController.text.isNotEmpty && textEditingController.text.isEmpty) {
                  textEditingController.text = _pmNameController.text;
                }
                return TextFormField(
                  controller: textEditingController,
                  focusNode: focusNode,
                  decoration: const InputDecoration(labelText: 'PM Full Name *', border: OutlineInputBorder()),
                  validator: (v) => _isInsurance && (v == null || v.isEmpty) ? 'Required' : null,
                  onChanged: (v) => setState(() => _pmNameController.text = v),
                );
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pmCompanyController,
              decoration: const InputDecoration(labelText: 'Company Name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pmEmailController,
              decoration: const InputDecoration(labelText: 'PM Email', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pmPhoneController,
              decoration: const InputDecoration(labelText: 'PM Phone', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pmBillingAddressController,
              decoration: const InputDecoration(labelText: 'Billing Address', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pmAssistantEmailsController,
              decoration: const InputDecoration(labelText: 'Assistant PM Emails (Comma separated)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pmBillingEmailsController,
              decoration: const InputDecoration(labelText: 'Billing Emails (Comma separated)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              title: const Text('Update PM Record with these changes?', style: TextStyle(color: Color(0xFFE65100), fontWeight: FontWeight.bold)),
              value: _updatePmRecord,
              onChanged: (v) => setState(() => _updatePmRecord = v ?? false),
              tileColor: const Color(0xFFFFF3E0),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildVisitDetails() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Visit Status *', border: OutlineInputBorder()),
              value: _visitStatus,
              items: const [
                DropdownMenuItem(value: 'To Be Scheduled', child: Text('To Be Scheduled')),
                DropdownMenuItem(value: 'Confirmed date', child: Text('Confirmed date')),
                DropdownMenuItem(value: 'Quote Only (No Visit)', child: Text('Quote Only (No Visit)')),
              ],
              onChanged: (v) => setState(() => _visitStatus = v),
              validator: (v) => v == null ? 'Required' : null,
            ),
            if (_isConfirmedVisit) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final date = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                        if (date != null && context.mounted) {
                          final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                          if (time != null) {
                            setState(() => _visitRequestedStart = DateTime(date.year, date.month, date.day, time.hour, time.minute));
                          }
                        }
                      },
                      icon: const Icon(Icons.calendar_today),
                      label: Text(_visitRequestedStart == null ? 'Requested Start *' : _visitRequestedStart.toString()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final date = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                        if (date != null && context.mounted) {
                          final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                          if (time != null) {
                            setState(() => _visitRequestedEnd = DateTime(date.year, date.month, date.day, time.hour, time.minute));
                          }
                        }
                      },
                      icon: const Icon(Icons.schedule),
                      label: Text(_visitRequestedEnd == null ? 'Requested End *' : _visitRequestedEnd.toString()),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Access Instructions', border: OutlineInputBorder()),
              value: _accessInstructions,
              items: const [
                DropdownMenuItem(value: 'Contact PM', child: Text('Contact PM')),
                DropdownMenuItem(value: 'Contact Client', child: Text('Contact Client')),
                DropdownMenuItem(value: 'Crew on site - Reg hrs', child: Text('Crew on site - Reg hrs')),
                DropdownMenuItem(value: 'Crew on site - 24 hrs', child: Text('Crew on site - 24 hrs')),
                DropdownMenuItem(value: 'Lockbox', child: Text('Lockbox')),
              ],
              onChanged: (v) => setState(() => _accessInstructions = v),
            ),
            if (_isLockbox) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _lockboxCodeController,
                decoration: const InputDecoration(labelText: 'Lockbox Code', border: OutlineInputBorder()),
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _poNumberController,
              decoration: const InputDecoration(labelText: 'PO Number', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Emergency Dispatch *', border: OutlineInputBorder()),
              value: _emergencyDispatch,
              items: const [
                DropdownMenuItem(value: 'No', child: Text('No')),
                DropdownMenuItem(value: 'Yes', child: Text('Yes')),
              ],
              onChanged: (v) => setState(() => _emergencyDispatch = v ?? 'No'),
              validator: (v) => v == null ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Supporting Documents (PDF / Docs)', style: TextStyle(fontWeight: FontWeight.bold)),
                const Text('Uploads will be placed in the project\'s Drive folder automatically.', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Add Document(s)'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
                if (_supportingDocs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ...List.generate(_supportingDocs.length, (index) {
                    final file = _supportingDocs[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.insert_drive_file, size: 20),
                      title: Text(file.name),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, color: Colors.red, size: 20),
                        onPressed: () => _removeFile(index),
                      ),
                    );
                  }),
                ]
              ],
            ),
          ],
        ),
      ),
    );
  }
}
