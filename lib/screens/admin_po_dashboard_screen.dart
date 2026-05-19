import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:google_fonts/google_fonts.dart';

class AdminPoDashboardScreen extends StatefulWidget {
  @override
  _AdminPoDashboardScreenState createState() => _AdminPoDashboardScreenState();
}

class _AdminPoDashboardScreenState extends State<AdminPoDashboardScreen> {
  bool _isLoading = true;
  List<dynamic> _unassignedPOs = [];
  String? _error;
  List<String> _projectOptions = [];
  List<String> _accountOptions = [];

  @override
  void initState() {
    super.initState();
    _fetchUnassignedPOs();
    _fetchReviewOptions();
  }

  Future<void> _fetchReviewOptions() async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('getPoReviewOptions');
      final result = await callable.call();
      final data = result.data as Map<dynamic, dynamic>;
      setState(() {
        _projectOptions = List<String>.from(data['projects'] ?? []);
        _accountOptions = List<String>.from(data['accounts'] ?? []);
      });
    } catch (e) {
      print('Failed to load review options: $e');
    }
  }

  Future<void> _fetchUnassignedPOs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('getUnassignedPOs');
      final result = await callable.call();
      setState(() {
        _unassignedPOs = result.data as List<dynamic>;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load PO exceptions: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _updatePoRow(int rowIndex, String field, String newValue) async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('updateUnassignedPo');
      await callable.call({
        'rowIndex': rowIndex,
        'updates': { field: newValue }
      });
      // Optionally re-fetch after successful update
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update successful. This row will be re-processed by the AI shortly.')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
    }
  }

  void _showEditDialog(Map<String, dynamic> po, String fieldLabel, String fieldKey, String currentValue) {
    String? selectedValue = currentValue == 'Unassigned' || currentValue == 'Unknown' ? null : currentValue;
    final TextEditingController _controller = TextEditingController(text: currentValue);
    
    // Determine if we should use a dropdown or text field
    final bool useDropdown = (fieldKey == 'jobAddress' && _projectOptions.isNotEmpty) || 
                             (fieldKey == 'accountCategory' && _accountOptions.isNotEmpty);
    final List<String> options = fieldKey == 'jobAddress' ? _projectOptions : _accountOptions;

    // Ensure currentValue exists in options if using dropdown
    if (useDropdown && selectedValue != null && !options.contains(selectedValue)) {
      // If the current value isn't in the live list, we keep it but allow picking a new one
      // Flutter DropdownButton requires the value to be in the list or null
      selectedValue = null; 
    }

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF132030), // surface-container
              title: Text('Edit $fieldLabel', style: GoogleFonts.spaceGrotesk(color: Colors.white)),
              content: Container(
                width: double.maxFinite,
                child: useDropdown 
                  ? DropdownButtonFormField<String>(
                      value: selectedValue,
                      dropdownColor: const Color(0xFF1E2B3B),
                      style: GoogleFonts.inter(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Select $fieldLabel',
                        labelStyle: GoogleFonts.inter(color: Colors.white54),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: const Color(0xFF00E5FF))),
                      ),
                      items: options.map((String val) {
                        return DropdownMenuItem<String>(
                          value: val,
                          child: Container(
                            constraints: BoxConstraints(maxWidth: 300),
                            child: Text(val, overflow: TextOverflow.ellipsis)
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setDialogState(() {
                          selectedValue = val;
                        });
                      },
                    )
                  : TextField(
                      controller: _controller,
                      style: GoogleFonts.inter(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'New $fieldLabel',
                        labelStyle: GoogleFonts.inter(color: Colors.white54),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: const Color(0xFF00E5FF))),
                      ),
                    ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Cancel', style: GoogleFonts.inter(color: Colors.white54)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
                  onPressed: () {
                    final String finalValue = useDropdown ? (selectedValue ?? '') : _controller.text;
                    if (finalValue.isNotEmpty) {
                      Navigator.pop(context);
                      _updatePoRow(po['rowIndex'], fieldKey, finalValue);
                    }
                  },
                  child: Text('Save', style: GoogleFonts.spaceGrotesk(color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF061423), // Deep Navy Core
      appBar: AppBar(
        backgroundColor: const Color(0xFF061423),
        title: Text('Immediate Response Engine | PO Workbench', style: GoogleFonts.spaceGrotesk(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: const Color(0xFF00E5FF)),
            onPressed: _fetchUnassignedPOs,
          )
        ],
      ),
      body: _isLoading 
        ? Center(child: CircularProgressIndicator(color: const Color(0xFF00E5FF)))
        : _error != null
          ? Center(child: Text(_error!, style: TextStyle(color: Colors.redAccent)))
          : _unassignedPOs.isEmpty
            ? Center(child: Text('ALL CLEAR. NO UNASSIGNED POs.', style: GoogleFonts.spaceGrotesk(color: const Color(0xFF00E5FF), fontSize: 24, fontWeight: FontWeight.w700)))
            : Padding(
                padding: const EdgeInsets.all(24.0), // Aggressive padding (Bento Box standard)
                child: ListView.separated(
                  itemCount: _unassignedPOs.length,
                  separatorBuilder: (context, index) => SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final po = Map<String, dynamic>.from(_unassignedPOs[index]);
                    return Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF132030),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${po['vendorName']} - PO: ${po['poNumber']}', style: GoogleFonts.spaceGrotesk(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                              Text('${po['amount']}', style: GoogleFonts.spaceGrotesk(color: const Color(0xFF00E5FF), fontSize: 20, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          SizedBox(height: 8),
                          Text('Date: ${po['date']}', style: GoogleFonts.inter(color: Colors.white70)),
                          Text('Sync Status: ${po['syncStatus']}', style: GoogleFonts.inter(color: po['syncStatus'].toString().contains('Failed') ? Colors.redAccent : Colors.orangeAccent)),
                          if (po['systemNotes'] != null && po['systemNotes'].toString().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text('AI Notes: ${po['systemNotes']}', style: GoogleFonts.inter(color: Colors.white54, fontStyle: FontStyle.italic)),
                            ),
                          SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _buildEditableChip(po, 'Job Address', 'jobAddress', po['jobAddress'] ?? 'Unassigned'),
                              _buildEditableChip(po, 'Account/Category', 'accountCategory', po['accountCategory'] ?? 'Unassigned'),
                              _buildEditableChip(po, 'Payment Type', 'paymentType', po['paymentType'] ?? 'Unknown'),
                            ],
                          )
                        ],
                      ),
                    );
                  },
                ),
              ),
    );
  }

  Widget _buildEditableChip(Map<String, dynamic> po, String label, String fieldKey, String value) {
    final bool isEmpty = value == 'Unassigned' || value == 'Unknown' || value.isEmpty;
    return InkWell(
      onTap: () => _showEditDialog(po, label, fieldKey, value),
      borderRadius: BorderRadius.circular(9999),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E2B3B),
          borderRadius: BorderRadius.circular(9999), // Pill shape 
          border: Border.all(color: isEmpty ? Colors.redAccent.withOpacity(0.5) : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label: ', style: GoogleFonts.inter(color: Colors.white54, fontSize: 12)),
            Text(value.isEmpty ? 'MISSING' : value, style: GoogleFonts.spaceGrotesk(color: isEmpty ? Colors.redAccent : Colors.white, fontSize: 14)),
            SizedBox(width: 8),
            Icon(Icons.edit, size: 14, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}
