package com.example.gemini_live_interview

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.ParcelFileDescriptor
import android.view.WindowManager
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.OutputStream
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "com.interview.ai/mlkit"
        private const val EVENT_CHANNEL = "com.interview.ai/mlkit_stream"
        private const val GEMINI_OUTPUT_SAMPLE_RATE = 24000
    }

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val diarizer = SpeakerDiarizer()

    private var eventSink: EventChannel.EventSink? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var summarizer: Summarizer? = null
    private var recognitionJob: Job? = null

    @Volatile
    private var keepSttRunning: Boolean = false

    @Volatile
    private var pipeWriteStream: OutputStream? = null
    private var pipeReadPfd: ParcelFileDescriptor? = null
    private var audioTrack: AudioTrack? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initAudioTrack24k()

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
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
                            val out = pipeWriteStream
                            if (out != null) {
                                mainScope.launch(Dispatchers.IO) {
                                    try {
                                        out.write(bytes)
                                        out.flush()
                                    } catch (_: Exception) {
                                        // Pipe rotates cleanly across 60-minute segments
                                    }
                                }
                            }
                        }
                        result.success(null)
                    }

                    "playModelPcm24k" -> {
                        val bytes = call.argument<ByteArray>("pcm")
                        if (bytes != null) {
                            mainScope.launch(Dispatchers.IO) {
                                try {
                                    if (audioTrack?.playState != AudioTrack.PLAYSTATE_PLAYING) {
                                        audioTrack?.play()
                                    }
                                    audioTrack?.write(bytes, 0, bytes.size)
                                } catch (_: Exception) {}
                            }
                        }
                        result.success(null)
                    }

                    "clearModelAudio" -> {
                        try {
                            audioTrack?.pause()
                            audioTrack?.flush()
                            audioTrack?.play()
                        } catch (_: Exception) {}
                        result.success(null)
                    }

                    "stopOnDeviceStt" -> {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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

    private fun initAudioTrack24k() {
        val minBuf = AudioTrack.getMinBufferSize(
            GEMINI_OUTPUT_SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(4800)

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(GEMINI_OUTPUT_SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(minBuf * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audioTrack?.play()
    }

    private suspend fun startMlKitStreamingStt() {
        stopMlKitStreamingStt()
        diarizer.reset()
        keepSttRunning = true

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
                    emitEvent("status", "ML Kit Speech model ready (60-min mode active).")
                }
            }
        } else if (status == FeatureStatus.UNAVAILABLE) {
            emitEvent("status", "ML Kit Speech unavailable on this device; acoustic diarizer + Gemini Live active.")
            speechRecognizer = recognizer
            return
        }

        speechRecognizer = recognizer

        // Continuous recognition loop supporting up to 60-minute sessions:
        // If ML Kit completes an utterance stream after silence, it automatically re-opens the PFD pipe.
        recognitionJob = mainScope.launch {
            while (keepSttRunning && isActive) {
                try {
                    closePipeOnly()
                    val pipe = ParcelFileDescriptor.createPipe()
                    pipeReadPfd = pipe[0]
                    pipeWriteStream = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])

                    val request = speechRecognizerRequest {
                        audioSource = AudioSource.fromPfd(pipeReadPfd!!, AudioSource.Mode.STREAMING)
                    }

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
                                emitEvent("status", "ML Kit segment restarting (${response.error})...")
                            }

                            else -> {}
                        }
                    }
                } catch (_: Exception) {
                    // Automatically restart segment if session is still running
                }
                if (keepSttRunning) {
                    delay(250)
                }
            }
        }
    }

    private fun closePipeOnly() {
        try {
            pipeWriteStream?.close()
        } catch (_: Exception) {}
        try {
            pipeReadPfd?.close()
        } catch (_: Exception) {}
        pipeWriteStream = null
        pipeReadPfd = null
    }

    private fun stopMlKitStreamingStt() {
        keepSttRunning = false
        recognitionJob?.cancel()
        recognitionJob = null
        closePipeOnly()
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
                "On-device Gemini Nano (AICore) Summarization is not supported on this phone model. Using Gemini Cloud Summary."
            )
        }

        if (status == FeatureStatus.DOWNLOADABLE) {
            emitEvent("status", "Downloading Gemini Nano Summarization model via AICore...")
            withContext(Dispatchers.IO) {
                client.downloadFeature { }.await()
            }
        }

        // Support full 60-minute transcripts by summarizing 10,000-char windows and combining
        val chunkSize = 10000
        if (transcript.length <= chunkSize) {
            val req = SummarizationRequest.builder(transcript).build()
            return withContext(Dispatchers.IO) { client.runInference(req).await().summary }
        }

        val chunkSummaries = mutableListOf<String>()
        var offset = 0
        while (offset < transcript.length) {
            val end = minOf(offset + chunkSize, transcript.length)
            val slice = transcript.substring(offset, end)
            val req = SummarizationRequest.builder(slice).build()
            val partSummary = withContext(Dispatchers.IO) { client.runInference(req).await().summary }
            chunkSummaries.add(partSummary)
            offset = end
        }

        val combined = chunkSummaries.joinToString("\n")
        val finalReq = SummarizationRequest.builder(combined.takeLast(chunkSize)).build()
        return withContext(Dispatchers.IO) { client.runInference(finalReq).await().summary }
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
        audioTrack?.release()
        mainScope.cancel()
        super.onDestroy()
    }
}
