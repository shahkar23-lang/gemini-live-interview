package com.example.gemini_live_interview

import android.os.ParcelFileDescriptor
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.speechrecognition.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerResponse
import com.google.mlkit.genai.speechrecognition.speechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.speechRecognizerRequest
import com.google.mlkit.genai.summarization.Summarization
import com.google.mlkit.genai.summarization.SummarizationRequest
import com.google.mlkit.genai.summarization.Summarizer
import com.google.mlkit.genai.summarization.SummarizerOptions
import com.google.mlkit.genai.summarization.SummarizerOptions.InputType
import com.google.mlkit.genai.summarization.SummarizerOptions.Language
import com.google.mlkit.genai.summarization.SummarizerOptions.OutputType
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.OutputStream
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "com.interview.ai/mlkit"
        private const val EVENT_CHANNEL = "com.interview.ai/mlkit_stream"
    }

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val diarizer = SpeakerDiarizer()

    private var eventSink: EventChannel.EventSink? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var summarizer: Summarizer? = null
    private var recognitionJob: Job? = null
    private var pipeWriteStream: OutputStream? = null
    private var pipeReadPfd: ParcelFileDescriptor? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startOnDeviceStt" -> {
                        mainScope.launch {
                            try {
                                startMlKitStreamingStt()
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("MLKIT_STT_ERR", e.message, null)
                            }
                        }
                    }

                    "feedPcmChunk" -> {
                        val bytes = call.argument<ByteArray>("pcm")
                        if (bytes != null) {
                            diarizer.processPcmChunk(bytes)
                            mainScope.launch(Dispatchers.IO) {
                                try {
                                    pipeWriteStream?.write(bytes)
                                    pipeWriteStream?.flush()
                                } catch (_: Exception) {
                                    // Pipe may close when session stops
                                }
                            }
                        }
                        result.success(null)
                    }

                    "stopOnDeviceStt" -> {
                        stopMlKitStreamingStt()
                        result.success(true)
                    }

                    "resetDiarizer" -> {
                        diarizer.reset()
                        result.success(true)
                    }

                    "summarizeOnDevice" -> {
                        val transcript = call.argument<String>("transcript") ?: ""
                        mainScope.launch {
                            try {
                                val summary = runMlKitOnDeviceSummarization(transcript)
                                result.success(summary)
                            } catch (e: Exception) {
                                result.error("MLKIT_SUM_ERR", e.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private suspend fun startMlKitStreamingStt() {
        stopMlKitStreamingStt()
        diarizer.reset()

        // Try MODE_ADVANCED (Gemini Nano / AICore) and fall back to MODE_BASIC if unsupported
        var recognizer = SpeechRecognition.getClient(
            speechRecognizerOptions {
                locale = Locale.US
                preferredMode = SpeechRecognizerOptions.Mode.MODE_ADVANCED
            }
        )

        var status = recognizer.checkStatus()
        if (status == FeatureStatus.UNAVAILABLE) {
            recognizer.close()
            recognizer = SpeechRecognition.getClient(
                speechRecognizerOptions {
                    locale = Locale.US
                    preferredMode = SpeechRecognizerOptions.Mode.MODE_BASIC
                }
            )
            status = recognizer.checkStatus()
        }

        if (status == FeatureStatus.DOWNLOADABLE) {
            emitEvent("status", "Downloading on-device ML Kit Speech model...")
            recognizer.download().collect { dl ->
                if (dl is DownloadStatus.DownloadCompleted) {
                    emitEvent("status", "ML Kit Speech model ready.")
                }
            }
        } else if (status == FeatureStatus.UNAVAILABLE) {
            emitEvent("status", "ML Kit GenAI Speech unavailable on this device; acoustic diarizer active.")
            speechRecognizer = recognizer
            return
        }

        speechRecognizer = recognizer

        // Create a streaming ParcelFileDescriptor pipe fed by Flutter's 16kHz 16-bit mono PCM chunks
        val pipe = ParcelFileDescriptor.createPipe()
        pipeReadPfd = pipe[0]
        pipeWriteStream = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])

        val request = speechRecognizerRequest {
            audioSource = AudioSource.fromPfd(pipeReadPfd!!, AudioSource.Mode.STREAMING)
        }

        recognitionJob = mainScope.launch {
            try {
                recognizer.startRecognition(request).collect { response ->
                    when (response) {
                        is SpeechRecognizerResponse.PartialTextResponse -> {
                            emitTranscript(
                                text = response.text,
                                speaker = diarizer.activeSpeakerLabel,
                                isFinal = false
                            )
                        }

                        is SpeechRecognizerResponse.FinalTextResponse -> {
                            val speaker = diarizer.finalizeUtteranceSpeaker()
                            if (response.text.isNotBlank()) {
                                emitTranscript(
                                    text = response.text,
                                    speaker = speaker,
                                    isFinal = true
                                )
                            }
                        }

                        is SpeechRecognizerResponse.ErrorResponse -> {
                            emitEvent("error", "ML Kit Speech error: ${response.error}")
                        }

                        else -> {}
                    }
                }
            } catch (e: Exception) {
                emitEvent("error", "ML Kit stream stopped: ${e.message}")
            }
        }
    }

    private fun stopMlKitStreamingStt() {
        recognitionJob?.cancel()
        recognitionJob = null
        try {
            pipeWriteStream?.close()
        } catch (_: Exception) {}
        try {
            pipeReadPfd?.close()
        } catch (_: Exception) {}
        pipeWriteStream = null
        pipeReadPfd = null
        speechRecognizer?.close()
        speechRecognizer = null
    }

    private suspend fun runMlKitOnDeviceSummarization(transcript: String): String {
        if (transcript.isBlank()) return "No interview transcript available to summarize."

        val options = SummarizerOptions.builder(applicationContext)
            .setInputType(InputType.CONVERSATION)
            .setOutputType(OutputType.THREE_BULLETS)
            .setLanguage(Language.ENGLISH)
            .build()

        val client = Summarization.getClient(options)
        summarizer?.close()
        summarizer = client

        val status = withContext(Dispatchers.IO) {
            client.checkFeatureStatus().await()
        }

        if (status == FeatureStatus.UNAVAILABLE) {
            throw IllegalStateException(
                "On-device Gemini Nano (AICore) Summarization is not supported on this phone model. Falling back to Gemini Cloud Summary."
            )
        }

        if (status == FeatureStatus.DOWNLOADABLE) {
            emitEvent("status", "Downloading Gemini Nano Summarization model via AICore...")
            withContext(Dispatchers.IO) {
                client.downloadFeature { }.await()
            }
        }

        val boundedInput = transcript.takeLast(12000)
        val request = SummarizationRequest.builder(boundedInput).build()
        val result = withContext(Dispatchers.IO) {
            client.runInference(request).await()
        }
        return result.summary
    }

    private fun emitTranscript(text: String, speaker: String, isFinal: Boolean) {
        mainScope.launch(Dispatchers.Main) {
            eventSink?.success(
                mapOf(
                    "type" to "transcript",
                    "text" to text,
                    "speaker" to speaker,
                    "isFinal" to isFinal
                )
            )
        }
    }

    private fun emitEvent(type: String, message: String) {
        mainScope.launch(Dispatchers.Main) {
            eventSink?.success(
                mapOf(
                    "type" to type,
                    "message" to message
                )
            )
        }
    }

    override fun onDestroy() {
        stopMlKitStreamingStt()
        summarizer?.close()
        mainScope.cancel()
        super.onDestroy()
    }
}
