import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import '../services/generative_ai_service.dart';

class TechnicalSummaryWidget extends StatelessWidget {
  final TechnicalReadings readings;

  const TechnicalSummaryWidget({super.key, required this.readings});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'HEALTH AUDIT SUMMARY',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 10,
            letterSpacing: 1.2,
            color: Color(0xFF3498DB),
          ),
        ),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.8,
          children: [
            _buildGauge(
              title: 'GAS PRESSURE',
              value: readings.gasPressure,
              min: 0,
              max: 15,
              unit: 'WC',
              ranges: [
                GaugeRange(startValue: 0, endValue: 3.2, color: Colors.orange),
                GaugeRange(startValue: 3.2, endValue: 3.8, color: Colors.green),
                GaugeRange(startValue: 3.8, endValue: 15, color: Colors.red),
              ],
            ),
            _buildGauge(
              title: 'STATIC PRESSURE',
              value: readings.staticPressure,
              min: 0,
              max: 2.0,
              unit: 'WC',
              ranges: [
                GaugeRange(startValue: 0, endValue: 0.5, color: Colors.green),
                GaugeRange(startValue: 0.5, endValue: 0.8, color: Colors.orange),
                GaugeRange(startValue: 0.8, endValue: 2.0, color: Colors.red),
              ],
            ),
            _buildGauge(
              title: 'TEMP RISE',
              value: readings.tempRise,
              min: 0,
              max: 100,
              unit: '°F',
              ranges: [
                GaugeRange(startValue: 0, endValue: 30, color: Colors.blue),
                GaugeRange(startValue: 30, endValue: 60, color: Colors.green),
                GaugeRange(startValue: 60, endValue: 100, color: Colors.red),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _getStatusColor(readings.status).withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _getStatusColor(readings.status).withOpacity(0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.analytics_outlined, color: _getStatusColor(readings.status)),
              const SizedBox(width: 12),
              Text(
                'SYSTEM STATUS: ${readings.status.toUpperCase()}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _getStatusColor(readings.status),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'normal': return Colors.green;
      case 'warning': return Colors.orange;
      case 'critical': return Colors.red;
      default: return Colors.grey;
    }
  }

  Widget _buildGauge({
    required String title,
    required double value,
    required double min,
    required double max,
    required String unit,
    required List<GaugeRange> ranges,
  }) {
    return Column(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.blueGrey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: SfRadialGauge(
            axes: <RadialAxis>[
              RadialAxis(
                minimum: min,
                maximum: max,
                showLabels: false,
                showTicks: false,
                axisLineStyle: const AxisLineStyle(thickness: 0.2, thicknessUnit: GaugeSizeUnit.factor),
                ranges: ranges,
                pointers: <GaugePointer>[
                  NeedlePointer(
                    value: value,
                    needleLength: 0.6,
                    needleStartWidth: 1,
                    needleEndWidth: 3,
                    knobStyle: const KnobStyle(knobRadius: 0.08),
                  ),
                ],
                annotations: <GaugeAnnotation>[
                  GaugeAnnotation(
                    widget: Text(
                      '$value\n$unit',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    angle: 90,
                    positionFactor: 0.5,
                  )
                ],
              )
            ],
          ),
        ),
      ],
    );
  }
}
