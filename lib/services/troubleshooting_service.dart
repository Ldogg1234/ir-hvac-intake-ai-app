import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:csv/csv.dart';

class TroubleshootingResult {
  final String brand;
  final String faultCode;
  final String symptom;
  final String likelyCulprit;
  final String canadianContextTip;
  final String severity;

  TroubleshootingResult({
    required this.brand,
    required this.faultCode,
    required this.symptom,
    required this.likelyCulprit,
    required this.canadianContextTip,
    required this.severity,
  });
}

class TroubleshootingService {
  static const String _csvPath = 'assets/data/hvac_troubleshooting_master.csv';

  Future<TroubleshootingResult?> lookupFault(String brand, String faultCode) async {
    try {
      final String rawCsv = await rootBundle.loadString(_csvPath);
      // Use the converter properly
      final List<List<dynamic>> rows = const CsvToListConverter().convert(rawCsv);

      if (rows.isEmpty) return null;

      // Skip header row
      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 6) continue;

        final String rowBrand = row[0].toString().trim().toLowerCase();
        final String rowFaultCode = row[1].toString().trim().toLowerCase();

        if (rowBrand == brand.toLowerCase().trim() && 
            rowFaultCode == faultCode.toLowerCase().trim()) {
          return TroubleshootingResult(
            brand: row[0].toString(),
            faultCode: row[1].toString(),
            symptom: row[2].toString(),
            likelyCulprit: row[3].toString(),
            canadianContextTip: row[4].toString(),
            severity: row[5].toString(),
          );
        }
      }
    } catch (e) {
      debugPrint('Error parsing troubleshooting CSV: $e');
    }
    return null;
  }
}
