import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/interview_models.dart';
import 'mlkit_native_bridge.dart';

class InterviewSummaryService {
  final MlKitNativeBridge _mlKitBridge;

  InterviewSummaryService(this._mlKitBridge);

  Future<InterviewSummaryResult> generateHybridSummary({
    required String apiKey,
    required List<TranscriptEntry> entries,
  }) async {
    final formattedTranscript = entries
        .map((e) => '[${e.speaker}]: ${e.text}')
        .join('\n');

    // 1. Attempt On-Device ML Kit GenAI Summarization (Gemini Nano via AICore)
    String? onDeviceBullets;
    try {
      onDeviceBullets = await _mlKitBridge.summarizeOnDevice(formattedTranscript);
    } catch (e) {
      onDeviceBullets = 'Unavailable on this device ($e)';
    }

    // 2. Structured Cloud Interview Summary + Speaker Role Diarization Mapping
    if (apiKey.trim().isEmpty) {
      return InterviewSummaryResult(
        onDeviceBullets: onDeviceBullets,
        executiveSummary: onDeviceBullets ?? 'Provide a Gemini API key for full cloud analysis.',
        speakerRoles: const {},
        keyStrengths: const [],
        followUpQuestions: const [],
        hiringRecommendation: 'N/A (Offline Mode)',
      );
    }

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
    );

    final prompt = '''
Analyze the following diarized interview transcript and return ONLY valid JSON matching this schema:
{
  "executiveSummary": "Concise 3-4 sentence overview of the interview",
  "speakerRoles": {"Speaker 1": "Interviewer (or Candidate)", "Speaker 2": "Candidate (or Interviewer)"},
  "keyStrengths": ["Strength 1", "Strength 2"],
  "followUpQuestions": ["Suggested follow-up 1", "Suggested follow-up 2"],
  "hiringRecommendation": "Strong Hire | Hire | Leaning No | Insufficient Signal — with 1 sentence rationale"
}

Transcript:
$formattedTranscript
''';

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
        },
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Gemini Summary API error (${response.statusCode}): ${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final rawJsonText =
        body['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '{}';
    final parsed = jsonDecode(rawJsonText) as Map<String, dynamic>;

    final rolesRaw = parsed['speakerRoles'] as Map<String, dynamic>? ?? {};

    return InterviewSummaryResult(
      onDeviceBullets: onDeviceBullets,
      executiveSummary: parsed['executiveSummary'] as String? ?? '',
      speakerRoles: rolesRaw.map((k, v) => MapEntry(k, v.toString())),
      keyStrengths: (parsed['keyStrengths'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      followUpQuestions: (parsed['followUpQuestions'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      hiringRecommendation: parsed['hiringRecommendation'] as String? ?? 'Pending',
    );
  }
}
