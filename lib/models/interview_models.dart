class TranscriptEntry {
  final String id;
  String speaker;
  final String text;
  final DateTime timestamp;
  final bool isFromGeminiModel;
  final bool isOnDeviceMlKit;

  TranscriptEntry({
    required this.id,
    required this.speaker,
    required this.text,
    required this.timestamp,
    this.isFromGeminiModel = false,
    this.isOnDeviceMlKit = false,
  });
}

class InterviewSummaryResult {
  final String? onDeviceBullets;
  final String executiveSummary;
  final Map<String, String> speakerRoles;
  final List<String> keyStrengths;
  final List<String> followUpQuestions;
  final String hiringRecommendation;

  const InterviewSummaryResult({
    this.onDeviceBullets,
    required this.executiveSummary,
    required this.speakerRoles,
    required this.keyStrengths,
    required this.followUpQuestions,
    required this.hiringRecommendation,
  });
}
