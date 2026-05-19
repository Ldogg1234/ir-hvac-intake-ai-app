import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import '../services/firebase_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

class AdminReportReviewScreen extends StatefulWidget {
  final String leadId;

  const AdminReportReviewScreen({super.key, required this.leadId});

  @override
  State<AdminReportReviewScreen> createState() => _AdminReportReviewScreenState();
}

class _AdminReportReviewScreenState extends State<AdminReportReviewScreen> {
  final FirebaseService _firebaseService = FirebaseService();
  final TextEditingController _summaryController = TextEditingController();
  
  Map<String, dynamic>? _reportData;
  bool _isLoading = true;
  bool _isGenerating = false;
  String? _generatedPdfUrl;

  @override
  void initState() {
    super.initState();
    _loadReport();
  }

  Future<void> _loadReport() async {
    final data = await _firebaseService.getReportForLead(widget.leadId);
    if (mounted) {
      setState(() {
        _reportData = data;
        _summaryController.text = data?['executiveSummary'] ?? '';
        _isLoading = false;
      });
    }
  }

  Future<void> _approveAndGenerate() async {
    setState(() => _isGenerating = true);
    
    // In a real app, we'd save the edited summary first
    // await _firebaseService.updateReportSummary(widget.leadId, _summaryController.text);

    final pdfUrl = await _firebaseService.generatePdfReport(widget.leadId);
    
    if (mounted) {
      setState(() {
        _isGenerating = false;
        _generatedPdfUrl = pdfUrl;
      });
      
      if (pdfUrl != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report Approved & PDF Generated!'), backgroundColor: Colors.green),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_reportData == null) {
      return const Scaffold(body: Center(child: Text('Report not found.')));
    }

    final metrics = _reportData!['technicalMetrics'] as List<dynamic>? ?? [];
    final equipment = _reportData!['equipmentId'] as Map<dynamic, dynamic>? ?? {};

    return Scaffold(
      appBar: AppBar(
        title: const Text('INSURANCE CLAIM VALIDATION', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        backgroundColor: const Color(0xFF1D2125),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEquipmentHeader(equipment),
            const SizedBox(height: 32),
            const Text(
              'TECHNICAL AUDIT & EVIDENCE',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.5, color: Color(0xFF3498DB)),
            ),
            const SizedBox(height: 16),
            ...metrics.map((m) => _buildMetricReviewRow(m as Map<String, dynamic>)).toList(),
            const SizedBox(height: 32),
            const Text(
              'REPORTER EXECUTIVE SUMMARY (EDITABLE)',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Colors.blueGrey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _summaryController,
              maxLines: 10,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                hintText: 'Tweak AI professional fluff here...',
              ),
              style: const TextStyle(fontSize: 14, height: 1.6),
            ),
            const SizedBox(height: 40),
            if (_generatedPdfUrl == null)
              _buildApprovalButton()
            else
              _buildSuccessActions(),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  Widget _buildEquipmentHeader(Map<dynamic, dynamic> equipment) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          const Icon(Icons.settings_input_component, size: 40, color: Color(0xFF3498DB)),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${equipment['brand'] ?? 'BRAND'} ${equipment['model'] ?? 'MODEL'}',
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                ),
                Text(
                  'S/N: ${equipment['serial'] ?? 'UNKNOWN'} • ${equipment['age'] ?? '?'} Years Old',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Text(
              equipment['refrigerant'] ?? 'R410A',
              style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricReviewRow(Map<String, dynamic> metric) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Gauge side
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), bottomLeft: Radius.circular(12)),
                  border: Border.all(color: Colors.black.withOpacity(0.05)),
                ),
                child: Column(
                  children: [
                    Text(
                      metric['metric']?.toString().toUpperCase() ?? 'METRIC',
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10, color: Colors.blueGrey),
                    ),
                    const SizedBox(height: 8),
                    Expanded(child: _buildSimpleGauge(metric)),
                    const SizedBox(height: 8),
                    Text(
                      'REC: ${metric['recommended'] ?? 'N/A'}',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green),
                    ),
                  ],
                ),
              ),
            ),
            // Evidence side
            Expanded(
              flex: 5,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.only(topRight: Radius.circular(12), bottomRight: Radius.circular(12)),
                  image: metric['sourcePhotoUrl'] != null 
                    ? DecorationImage(image: NetworkImage(metric['sourcePhotoUrl']), fit: BoxFit.cover)
                    : null,
                  color: Colors.grey[200],
                ),
                child: metric['sourcePhotoUrl'] == null 
                  ? const Center(child: Icon(Icons.no_photography_outlined, color: Colors.grey))
                  : const Stack(
                      children: [
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Icon(Icons.verified, color: Colors.green, size: 20),
                        ),
                      ],
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimpleGauge(Map<String, dynamic> metric) {
    final double val = (metric['value'] ?? 0.0).toDouble();
    final String status = metric['status'] ?? 'safe';
    Color needleColor = Colors.green;
    if (status == 'warning') needleColor = Colors.orange;
    if (status == 'dangerous') needleColor = Colors.red;

    return SfRadialGauge(
      axes: <RadialAxis>[
        RadialAxis(
          minimum: 0,
          maximum: 100, // Normalized for visual consistency, or use real ranges
          showLabels: false,
          showTicks: false,
          axisLineStyle: const AxisLineStyle(thickness: 0.2, thicknessUnit: GaugeSizeUnit.factor),
          pointers: <GaugePointer>[
            NeedlePointer(
              value: val,
              needleLength: 0.7,
              needleColor: needleColor,
              knobStyle: KnobStyle(color: needleColor, knobRadius: 0.1),
            ),
          ],
          annotations: <GaugeAnnotation>[
            GaugeAnnotation(
              widget: Text(
                '$val\n${metric['unit'] ?? ''}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              angle: 90,
              positionFactor: 0.5,
            )
          ],
        )
      ],
    );
  }

  Widget _buildApprovalButton() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(color: Colors.green.withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 10)),
        ],
      ),
      child: ElevatedButton(
        onPressed: _isGenerating ? null : _approveAndGenerate,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        child: _isGenerating
          ? const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                SizedBox(width: 12),
                Text('GENERATING BRANDED PDF...', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            )
          : const Text('APPROVE & GENERATE PDF', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
      ),
    );
  }

  Widget _buildSuccessActions() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.withOpacity(0.3))),
          child: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 12),
              Text('Audit Validated & PDF Ready', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _viewPdf(),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('VIEW PDF'),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _sendToPm(),
                icon: const Icon(Icons.send),
                label: const Text('SEND TO PM'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3498DB),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => context.push('/admin/estimate/\${widget.leadId}'),
            icon: const Icon(Icons.request_quote),
            label: const Text('BUILD ESTIMATE'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              foregroundColor: Colors.orange,
              side: const BorderSide(color: Colors.orange),
            ),
          ),
        ),
      ],
    );
  }

  void _viewPdf() async {
    if (_generatedPdfUrl != null) {
      final uri = Uri.parse(_generatedPdfUrl!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    }
  }

  void _sendToPm() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report sent to Project Manager & Adjuster.'), backgroundColor: Colors.blue),
    );
  }
}
