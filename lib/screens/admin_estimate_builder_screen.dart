import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';

// Brand Colors
const Color _primaryColor = Color(0xFFA2D9F7);
const Color _secondaryColor = Color(0xFF000000);
const Color _bgColor = Color(0xFFF8FAFC);
const Color _surfaceColor = Colors.white;

class AdminEstimateBuilderScreen extends StatefulWidget {
  final String leadId;

  const AdminEstimateBuilderScreen({super.key, required this.leadId});

  @override
  State<AdminEstimateBuilderScreen> createState() => _AdminEstimateBuilderScreenState();
}

class _AdminEstimateBuilderScreenState extends State<AdminEstimateBuilderScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isGeneratingDoc = false;
  bool _isGeneratingPdf = false;
  String? _currentEstimateId;
  String? _draftDocUrl;
  String? _finalPdfUrl;

  Map<String, dynamic>? _leadData;
  List<Map<String, dynamic>> _priceBookItems = [];

  final TextEditingController _introCtrl = TextEditingController();
  final TextEditingController _conclusionCtrl = TextEditingController();

  final List<LineItem> _lineItems = [];

  @override
  void dispose() {
    _introCtrl.dispose();
    _conclusionCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('leads').doc(widget.leadId).get();
      if (doc.exists) {
        _leadData = doc.data();
      }

      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('getPriceBookItems');
      final result = await callable.call();

      if (result.data['success'] == true) {
        final List<dynamic> rawItems = result.data['result'];
        _priceBookItems = rawItems.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Error loading estimate builder data: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  InputDecoration _customInputDecoration(String label, {IconData? icon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: icon != null ? Icon(icon, color: _primaryColor) : null,
      filled: true,
      fillColor: _bgColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _primaryColor, width: 2),
      ),
    );
  }

  void _showAddItemDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Add Line Item', style: TextStyle(color: _primaryColor, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: ListView.separated(
              itemCount: _priceBookItems.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = _priceBookItems[index];
                final price = (item['base_price'] ?? 0).toDouble();
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  title: Text(item['item_name'] ?? 'Unknown Item', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  subtitle: item['description'] != null ? Text(item['description'], maxLines: 2, overflow: TextOverflow.ellipsis) : null,
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(20)),
                    child: Text(NumberFormat.currency(symbol: '\$').format(price), style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.bold)),
                  ),
                  onTap: () {
                    setState(() {
                      _lineItems.add(LineItem(
                        id: FirebaseFirestore.instance.collection('tmp').doc().id,
                        name: item['item_name'],
                        description: item['description'],
                        qty: 1,
                        rate: price,
                        approved: true,
                      ));
                    });
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _secondaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                Navigator.pop(context);
                _showCustomItemDialog();
              },
              icon: const Icon(Icons.edit),
              label: const Text('CUSTOM ITEM'),
            ),
          ],
        );
      },
    );
  }

  void _showCustomItemDialog() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final rateCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Add Custom Item', style: TextStyle(color: _primaryColor, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: _customInputDecoration('Item Name', icon: Icons.label)),
              const SizedBox(height: 16),
              TextField(controller: descCtrl, decoration: _customInputDecoration('Description', icon: Icons.description)),
              const SizedBox(height: 16),
              TextField(controller: rateCtrl, decoration: _customInputDecoration('Rate (\$)', icon: Icons.attach_money), keyboardType: TextInputType.number),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              onPressed: () {
                final rate = double.tryParse(rateCtrl.text) ?? 0.0;
                if (nameCtrl.text.isNotEmpty) {
                  setState(() {
                    _lineItems.add(LineItem(
                      id: FirebaseFirestore.instance.collection('tmp').doc().id,
                      name: nameCtrl.text,
                      description: descCtrl.text,
                      qty: 1,
                      rate: rate,
                      approved: true,
                    ));
                  });
                  Navigator.pop(context);
                }
              },
              child: const Text('ADD ITEM', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showAIParsingDialog() {
    final textCtrl = TextEditingController();
    bool isParsing = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: _primaryColor),
                  SizedBox(width: 12),
                  Text('AI Report Parser', style: TextStyle(color: _primaryColor, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SizedBox(
                width: 600,
                child: isParsing 
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 32),
                        const CircularProgressIndicator(color: _secondaryColor),
                        const SizedBox(height: 24),
                        Text('Vertex AI is analyzing the report...', style: TextStyle(fontSize: 16, color: Colors.grey.shade700)),
                        const SizedBox(height: 32),
                      ],
                    )
                  : TextField(
                      controller: textCtrl,
                      maxLines: 15,
                      decoration: InputDecoration(
                        hintText: 'Paste the unstructured narrative report here...',
                        filled: true,
                        fillColor: _bgColor,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      ),
                    ),
              ),
              actions: [
                if (!isParsing)
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL', style: TextStyle(color: Colors.grey))),
                if (!isParsing)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('PARSE REPORT', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
                    onPressed: () async {
                      if (textCtrl.text.trim().isEmpty) return;
                      setStateDialog(() => isParsing = true);
                      try {
                        final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
                        final callable = functions.httpsCallable('parseReportEstimate');
                        final result = await callable.call({'text': textCtrl.text});
                        
                        if (result.data['success'] == true) {
                          final data = result.data['data'];
                          setState(() {
                            if (data['introduction'] != null) _introCtrl.text = data['introduction'];
                            if (data['conclusion'] != null) _conclusionCtrl.text = data['conclusion'];
                            if (data['lineItems'] != null) {
                              for (var item in data['lineItems']) {
                                _lineItems.add(LineItem(
                                  id: FirebaseFirestore.instance.collection('tmp').doc().id,
                                  name: item['name'] ?? 'Unknown Item',
                                  description: item['description'] ?? '',
                                  qty: item['qty'] ?? 1,
                                  rate: (item['rate'] ?? 0).toDouble(),
                                  approved: true,
                                ));
                              }
                            }
                          });
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report data extracted successfully!'), backgroundColor: Colors.green));
                          }
                        }
                      } catch (e) {
                        debugPrint('Error parsing report: $e');
                        if (mounted) {
                          setStateDialog(() => isParsing = false);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error parsing: $e'), backgroundColor: Colors.red));
                        }
                      }
                    },
                  ),
              ],
            );
          }
        );
      },
    );
  }

  double _calculateTotal() {
    double total = 0;
    for (var item in _lineItems) total += (item.qty * item.rate);
    return total;
  }

  String _generateToken() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = math.Random();
    return List.generate(32, (index) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<String?> _saveEstimate({required String status, bool generateToken = false}) async {
    if (_lineItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please add at least one line item'), backgroundColor: Colors.red));
      return null;
    }

    setState(() => _isSaving = true);
    try {
      _currentEstimateId ??= FirebaseFirestore.instance.collection('estimates').doc().id;
      final estimateRef = FirebaseFirestore.instance.collection('estimates').doc(_currentEstimateId);
      final Map<String, dynamic> pmData = _leadData?['pm'] ?? {};

      Map<String, dynamic> estimateData = {
        'id': _currentEstimateId,
        'lead_id': widget.leadId,
        'client_name': _leadData?['client_name'] ?? 'Unknown Client',
        'property_address': _leadData?['property_address'] ?? 'Unknown Address',
        'pm_name': pmData['full_name'] != null ? "${pmData['full_name']} (${pmData['company_name'] ?? ''})" : '',
        'po_number': _leadData?['job_type'] == 'Res_Insurance' ? 'Insurance Claim' : 'N/A',
        'date': DateTime.now().toIso8601String(),
        'validUntil': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
        'status': status,
        'introduction': _introCtrl.text,
        'conclusion': _conclusionCtrl.text,
        'lineItems': _lineItems.map((item) => {
          'id': item.id,
          'name': item.name,
          'description': item.description,
          'qty': item.qty,
          'rate': item.rate,
          'approved': item.approved,
        }).toList(),
      };

      if (generateToken) {
        final token = _generateToken();
        estimateData['secure_token'] = token;
      }

      await estimateRef.set(estimateData, SetOptions(merge: true));

      if (mounted) setState(() => _isSaving = false);
      return _currentEstimateId;
    } catch (e) {
      debugPrint('Error saving estimate: $e');
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.red));
      }
      return null;
    }
  }

  Future<void> _generateLink() async {
    final docId = await _saveEstimate(status: 'sent_to_client', generateToken: true);
    if (docId != null && mounted) {
      final docSnapshot = await FirebaseFirestore.instance.collection('estimates').doc(docId).get();
      final token = docSnapshot.data()?['secure_token'];
      if (token != null) _showLinkDialog(token);
    }
  }

  Future<void> _generateDocDraft() async {
    final estimateId = await _saveEstimate(status: 'draft');
    if (estimateId == null) return;

    setState(() => _isGeneratingDoc = true);
    try {
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('generateEstimateDoc');
      final result = await callable.call({'estimateId': estimateId});

      if (result.data['success'] == true) {
        setState(() {
          _draftDocUrl = result.data['url'];
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Google Doc Draft Generated!'), backgroundColor: Colors.green));
        }
      }
    } catch (e) {
      debugPrint('Error generating doc: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to generate doc: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isGeneratingDoc = false);
    }
  }

  Future<void> _generatePdf() async {
    if (_currentEstimateId == null) return;
    setState(() => _isGeneratingPdf = true);
    try {
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('generateEstimatePdf');
      final result = await callable.call({'estimateId': _currentEstimateId});

      if (result.data['success'] == true) {
        setState(() {
          _finalPdfUrl = result.data['url'];
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF Generated & Uploaded!'), backgroundColor: Colors.green));
        }
      }
    } catch (e) {
      debugPrint('Error generating PDF: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to generate PDF: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isGeneratingPdf = false);
    }
  }

  void _showLinkDialog(String token) {
    final link = 'https://immediateresponsehvac.ca/estimate.html?token=$token';
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 32),
              SizedBox(width: 12),
              Text('Estimate Generated!', style: TextStyle(color: _primaryColor, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The secure client portal link has been generated successfully. Copy the link below to send to the adjuster or client:', style: TextStyle(fontSize: 15)),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.blue.shade100)),
                child: SelectableText(link, style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blue.shade700, fontSize: 16)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('DONE', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _secondaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied to clipboard!'), backgroundColor: _primaryColor));
              },
              icon: const Icon(Icons.copy),
              label: const Text('COPY LINK', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(backgroundColor: _bgColor, body: Center(child: CircularProgressIndicator(color: _primaryColor)));
    }

    final total = _calculateTotal();

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Estimate Builder', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5)),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isSaving ? null : _generateLink,
        icon: _isSaving 
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
            : const Icon(Icons.send_rounded),
        label: Text(_isSaving ? 'SAVING...' : 'CREATE INTERACTIVE PORTAL', style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5)),
        backgroundColor: _secondaryColor,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: IgnorePointer(
          ignoring: _isSaving,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Project Info
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: _surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Wrap(
                  spacing: 48,
                  runSpacing: 24,
                  children: [
                    _buildMetaItem('Client / Insured', _leadData?['client_name'] ?? 'N/A', Icons.person),
                    _buildMetaItem('Property Address', _leadData?['property_address'] ?? 'N/A', Icons.location_on),
                    if (_leadData?['pm']?['full_name'] != null)
                      _buildMetaItem('Project Manager', "\${_leadData!['pm']['full_name']} (\${_leadData!['pm']['company_name'] ?? ''})", Icons.business_center),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // AI Parsing Section
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [_primaryColor, _primaryColor.withOpacity(0.9)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: _primaryColor.withOpacity(0.2), blurRadius: 15, offset: const Offset(0, 8))],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), shape: BoxShape.circle),
                      child: const Icon(Icons.auto_awesome, color: Colors.white, size: 36),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('AI Auto-Fill', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                          const SizedBox(height: 8),
                          Text('Paste an unstructured report. Our AI will automatically extract the introduction narrative, pricing, and all line items.', style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 15, height: 1.4)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _surfaceColor,
                        foregroundColor: _primaryColor,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                      ),
                      onPressed: _showAIParsingDialog,
                      icon: const Icon(Icons.paste),
                      label: const Text('PASTE REPORT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 48),

              // Narrative Intro
              const Text('Report Narrative', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _primaryColor)),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(color: _surfaceColor, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
                child: TextField(
                  controller: _introCtrl,
                  maxLines: 6,
                  decoration: _customInputDecoration('Introduction / Opening Remarks').copyWith(
                    fillColor: _surfaceColor,
                    hintText: 'Enter the opening narrative for the client...',
                  ),
                ),
              ),
              const SizedBox(height: 40),

              // Line Items
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Scope of Work & Pricing', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _primaryColor)),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _surfaceColor,
                      foregroundColor: _primaryColor,
                      side: const BorderSide(color: _primaryColor),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                    onPressed: _showAddItemDialog,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('ADD LINE ITEM', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              if (_lineItems.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(48),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _surfaceColor,
                    border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text('No Line Items Yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey.shade700)),
                      const SizedBox(height: 8),
                      Text('Add manually or use the AI Auto-Fill above.', style: TextStyle(color: Colors.grey.shade500)),
                    ],
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _lineItems.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final item = _lineItems[index];
                    return Container(
                      decoration: BoxDecoration(
                        color: _surfaceColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 5,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _primaryColor)),
                                const SizedBox(height: 6),
                                if (item.description != null && item.description!.isNotEmpty)
                                  Text(item.description!, style: TextStyle(color: Colors.grey.shade600, fontSize: 13, height: 1.4)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              initialValue: item.qty.toString(),
                              decoration: _customInputDecoration('Qty').copyWith(fillColor: _surfaceColor, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                              keyboardType: TextInputType.number,
                              onChanged: (val) => setState(() => _lineItems[index].qty = int.tryParse(val) ?? 1),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              initialValue: item.rate.toStringAsFixed(2),
                              decoration: _customInputDecoration('Rate').copyWith(fillColor: _surfaceColor, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              onChanged: (val) => setState(() => _lineItems[index].rate = double.tryParse(val) ?? 0.0),
                            ),
                          ),
                          const SizedBox(width: 24),
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            width: 100,
                            alignment: Alignment.centerRight,
                            child: Text(
                              NumberFormat.currency(symbol: '\$').format(item.qty * item.rate),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.black87),
                            ),
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            onPressed: () => setState(() => _lineItems.removeAt(index)),
                          ),
                        ],
                      ),
                    );
                  },
                ),

              if (_lineItems.isNotEmpty) ...[
                const SizedBox(height: 32),
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    width: 350,
                    decoration: BoxDecoration(
                      color: _primaryColor,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: _primaryColor.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Estimate Total', style: TextStyle(fontSize: 16, color: Colors.white70)),
                        Text(
                          NumberFormat.currency(symbol: '\$').format(total), 
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: -0.5),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 48),

                // Document Actions Area
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.blue.shade100),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.description, color: _primaryColor),
                          SizedBox(width: 12),
                          Text('Google Docs Draft & Final PDF Export', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _primaryColor)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text('Use this to generate a physical document instead of (or in addition to) the interactive portal link. Edit the Draft via the provided link before converting to PDF.', style: TextStyle(color: Colors.black54, fontSize: 14)),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _surfaceColor,
                                foregroundColor: _primaryColor,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                side: const BorderSide(color: _primaryColor),
                              ),
                              onPressed: _isGeneratingDoc ? null : _generateDocDraft,
                              icon: _isGeneratingDoc 
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.note_add),
                              label: const Text('GENERATE DOC DRAFT'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _primaryColor,
                                foregroundColor: _surfaceColor,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: (_isGeneratingPdf || _draftDocUrl == null) ? null : _generatePdf,
                              icon: _isGeneratingPdf 
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.picture_as_pdf),
                              label: const Text('FINALIZE to PDF'),
                            ),
                          ),
                        ],
                      ),
                      if (_draftDocUrl != null) ...[
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: _surfaceColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Draft Document URL:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                              const SizedBox(height: 8),
                              SelectableText(_draftDocUrl!, style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ],
                      if (_finalPdfUrl != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.shade200)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Final PDF Generated & Uploaded:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green.shade700)),
                              const SizedBox(height: 8),
                              SelectableText(_finalPdfUrl!, style: TextStyle(color: Colors.green.shade900, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                
                const SizedBox(height: 100), // Padding for FAB
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetaItem(String label, String value, IconData icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, color: _primaryColor, size: 20),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade500, letterSpacing: 0.5)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
          ],
        ),
      ],
    );
  }
}

class LineItem {
  String id;
  String name;
  String? description;
  int qty;
  double rate;
  bool approved;

  LineItem({
    required this.id,
    required this.name,
    this.description,
    required this.qty,
    required this.rate,
    this.approved = true,
  });
}
