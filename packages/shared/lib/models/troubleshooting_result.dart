/// A fault code lookup result from the troubleshooting CSV data warehouse.
class TroubleshootingResult {
  final String brand;
  final String faultCode;
  final String symptom;
  final String likelyCulprit;
  final String canadianContextTip;
  final String severity;

  const TroubleshootingResult({
    required this.brand,
    required this.faultCode,
    required this.symptom,
    required this.likelyCulprit,
    required this.canadianContextTip,
    required this.severity,
  });
}
