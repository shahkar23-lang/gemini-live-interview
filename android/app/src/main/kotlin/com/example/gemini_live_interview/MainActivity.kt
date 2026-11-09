package com.example.gemini_live_interview

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer as AndroidSpeechRecognizer
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.common.audio.AudioSource
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
        private const val REQ_RECORD_AUDIO = 901
    }

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val diarizer = SpeakerDiarizer()

    private var eventSink: EventChannel.EventSink? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var androidSpeechRecognizer: AndroidSpeechRecognizer? = null
    private var summarizer: Summarizer? = null
    private var recognitionJob: Job? = null
    private var pendingPermResult: MethodChannel.Result? = null

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
                    "ensureMicPermission" -> {
                        val granted = ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.RECORD_AUDIO
                        ) == PackageManager.PERMISSION_GRANTED
                        if (granted) {
                            result.success(true)
                        } else {
                            pendingPermResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.RECORD_AUDIO),
                                REQ_RECORD_AUDIO
                            )
                        }
                    }

                    "startOnDeviceStt" -> {
                        val usePfdPipe = call.argument<Boolean>("usePfdPipe") ?: false
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        // Return immediately so UI never blocks, and launch continuous STT
                        keepSttRunning = true
                        diarizer.reset()
                        mainScope.launch {
                            startContinuousSttEngine(usePfdPipe)
                        }
                        result.success(true)
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
                                    } catch (_: Exception) {}
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
                        stopAllSttEngines()
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_RECORD_AUDIO) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermResult?.success(granted)
            pendingPermResult = null
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

    /**
     * Checks if ML Kit GenAI Speech Recognition is already available on-device.
     * If available, runs ML Kit GenAI SpeechRecognition; otherwise immediately starts
     * Android's universal SpeechRecognizer in a continuous 60-minute hands-free loop.
     */
    private suspend fun startContinuousSttEngine(usePfdPipe: Boolean) {
        stopRecognitionEnginesOnly()

        var mlKitReady = false
        var recognizer: SpeechRecognizer? = null
        try {
            recognizer = SpeechRecognition.getClient(
                speechRecognizerOptions {
                    locale = Locale.getDefault()
                    preferredMode = SpeechRecognizerOptions.Mode.MODE_BASIC
                }
            )
            val status = recognizer.checkStatus()
            if (status == FeatureStatus.AVAILABLE) {
                mlKitReady = true
            } else {
                recognizer.close()
                recognizer = null
            }
        } catch (_: Exception) {
            try {
                recognizer?.close()
            } catch (_: Exception) {}
            recognizer = null
        }

        if (mlKitReady && recognizer != null) {
            speechRecognizer = recognizer
            emitEvent("status", "LIVE: On-Device ML Kit GenAI Speech active (Hands-Free 60m)")
            startMlKitLoop(recognizer, usePfdPipe)
        } else if (!usePfdPipe) {
            emitEvent("status", "LIVE: Android On-Device Speech Engine active (Hands-Free 60m)")
            startAndroidSpeechRecognizerLoop()
        } else {
            emitEvent("status", "LIVE: Gemini Live Audio Stream + Acoustic Diarizer active (Hands-Free 60m)")
        }
    }

    private fun startMlKitLoop(recognizer: SpeechRecognizer, usePfdPipe: Boolean) {
        recognitionJob = mainScope.launch {
            while (keepSttRunning && isActive) {
                try {
                    val source = if (usePfdPipe) {
                        closePipeOnly()
                        val pipe = ParcelFileDescriptor.createPipe()
                        pipeReadPfd = pipe[0]
                        pipeWriteStream = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
                        AudioSource.fromPfd(pipeReadPfd!!, AudioSource.Mode.STREAMING)
                    } else {
                        AudioSource.fromMic()
                    }

                    val request = speechRecognizerRequest {
                        audioSource = source
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
                                emitEvent("status", "Reconnecting speech segment (${response.e.message})...")
                            }

                            else -> {}
                        }
                    }
                } catch (_: Exception) {
                    if (keepSttRunning && !usePfdPipe) {
                        // Fall back to universal Android SpeechRecognizer if ML Kit stream errors
                        startAndroidSpeechRecognizerLoop()
                        return@launch
                    }
                }
                if (keepSttRunning) {
                    delay(150)
                }
            }
        }
    }

    /**
     * Universal Android SpeechRecognizer continuous 60-minute hands-free loop.
     * Automatically restarts within 80ms after each sentence or silence pause.
     */
    private fun startAndroidSpeechRecognizerLoop() {
        mainHandler.post {
            if (!keepSttRunning) return@post
            try {
                androidSpeechRecognizer?.destroy()
            } catch (_: Exception) {}

            val sr = AndroidSpeechRecognizer.createSpeechRecognizer(applicationContext)
            androidSpeechRecognizer = sr

            val recognizerIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                )
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                    2500L
                )
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                    2000L
                )
            }

            sr.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    emitEvent("status", "Listening hands-free (speak naturally)...")
                }

                override fun onBeginningOfSpeech() {}

                override fun onRmsChanged(rmsdB: Float) {
                    diarizer.processRmsFrame(rmsdB)
                    emitRms(rmsdB)
                }

                override fun onBufferReceived(buffer: ByteArray?) {
                    if (buffer != null && buffer.isNotEmpty()) {
                        diarizer.processPcmChunk(buffer)
                    }
                }

                override fun onEndOfSpeech() {}

                override fun onError(error: Int) {
                    if (!keepSttRunning) return
                    // Automatically restart continuous listening on silence timeouts or segment end
                    mainHandler.postDelayed({
                        if (keepSttRunning) {
                            try {
                                sr.startListening(recognizerIntent)
                            } catch (_: Exception) {
                                startAndroidSpeechRecognizerLoop()
                            }
                        }
                    }, 120L)
                }

                override fun onResults(results: Bundle?) {
                    val matches = results?.getStringArrayList(AndroidSpeechRecognizer.RESULTS_RECOGNITION)
                    val text = matches?.firstOrNull()?.trim() ?: ""
                    if (text.isNotEmpty()) {
                        val speaker = diarizer.finalizeUtteranceSpeaker()
                        emitTranscript(text = text, speaker = speaker, isFinal = true)
                    }
                    if (keepSttRunning) {
                        mainHandler.postDelayed({
                            if (keepSttRunning) {
                                try {
                                    sr.startListening(recognizerIntent)
                                } catch (_: Exception) {
                                    startAndroidSpeechRecognizerLoop()
                                }
                            }
                        }, 80L)
                    }
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val matches =
                        partialResults?.getStringArrayList(AndroidSpeechRecognizer.RESULTS_RECOGNITION)
                    val partial = matches?.firstOrNull()?.trim() ?: ""
                    if (partial.isNotEmpty()) {
                        emitTranscript(
                            text = partial,
                            speaker = diarizer.activeSpeakerLabel,
                            isFinal = false
                        )
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })

            try {
                sr.startListening(recognizerIntent)
            } catch (e: Exception) {
                emitEvent("error", "Mic recognition start error: ${e.message}")
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

    private fun stopRecognitionEnginesOnly() {
        recognitionJob?.cancel()
        recognitionJob = null
        closePipeOnly()
        try {
            speechRecognizer?.close()
        } catch (_: Exception) {}
        speechRecognizer = null

        mainHandler.post {
            try {
                androidSpeechRecognizer?.stopListening()
                androidSpeechRecognizer?.cancel()
                androidSpeechRecognizer?.destroy()
            } catch (_: Exception) {}
            androidSpeechRecognizer = null
        }
    }

    private fun stopAllSttEngines() {
        keepSttRunning = false
        stopRecognitionEnginesOnly()
    }

    private suspend fun runMlKitOnDeviceSummarization(transcript: String): String {
        if (transcript.isBlank()) return "No interview transcript available to summarize."

        val options = SummarizerOptions.builder(applicationContext)
            .setInputType(InputType.CONVERSATION)
            .setOutputType(OutputType.THREE_BULLETS)
            .setLanguage(Language.ENGLISH)
            .setLongInputAutoTruncationEnabled(true)
            .build()

        val client = Summarization.getClient(options)
        summarizer?.close()
        summarizer = client

        val status = withContext(Dispatchers.IO) {
            client.checkFeatureStatus().await()
        }

        if (status == FeatureStatus.UNAVAILABLE) {
            throw IllegalStateException("AICore Gemini Nano unavailable on this device")
        }

        if (status == FeatureStatus.DOWNLOADABLE) {
            emitEvent("status", "Downloading Gemini Nano Summarization model via AICore...")
            withContext(Dispatchers.IO) {
                client.downloadFeature(object : DownloadCallback {
                    override fun onDownloadStarted(bytesToDownload: Long) {}
                    override fun onDownloadFailed(e: GenAiException) {}
                    override fun onDownloadProgress(totalBytesDownloaded: Long) {}
                    override fun onDownloadCompleted() {}
                }).await()
            }
        }

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
        mainHandler.post {
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

    private fun emitRms(rmsdB: Float) {
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "type" to "rms",
                    "rmsdB" to rmsdB.toDouble()
                )
            )
        }
    }

    private fun emitEvent(type: String, message: String) {
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "type" to type,
                    "message" to message
                )
            )
        }
    }

    override fun onDestroy() {
        stopAllSttEngines()
        summarizer?.close()
        audioTrack?.release()
        mainScope.cancel()
        super.onDestroy()
    }
}
