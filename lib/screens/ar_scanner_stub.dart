import 'package:flutter/material.dart';

class ARScannerScreen extends StatelessWidget {
  final String leadId;
  final String scanId;

  const ARScannerScreen({
    Key? key,
    required this.leadId,
    required this.scanId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LiDAR Spatial Scanner'),
        backgroundColor: Colors.black87,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.warning_amber_rounded, size: 80, color: Colors.orange),
              SizedBox(height: 20),
              Text(
                'LiDAR Scanning Not Supported',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 10),
              Text(
                'The LiDAR spatial scanner requires native Apple ARKit hardware.\n\nIt cannot be run in a web browser like Safari or Chrome. Please install the native iOS app via Xcode or TestFlight to use this feature.',
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
