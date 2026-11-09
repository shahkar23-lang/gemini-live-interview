package com.example.gemini_live_interview

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Real-time on-device speaker diarizer supporting both:
 * 1) Raw 16kHz 16-bit PCM chunks (pitch F0, ZCR, spectral ratio, RMS energy)
 * 2) Android SpeechRecognizer RMS + cadence/turn-gap dynamics
 */
class SpeakerDiarizer(
    private val sampleRate: Int = 16000,
    private val maxSpeakers: Int = 2,
    private val similarityThreshold: Double = 0.88
) {
    private val speakerCentroids = mutableListOf<DoubleArray>()
    private val speakerCounts = mutableListOf<Int>()
    private val currentUtteranceVectors = mutableListOf<DoubleArray>()
    private val currentRmsValues = mutableListOf<Double>()

    private var lastUtteranceEndMs: Long = 0L
    private var currentSpeakerIndex: Int = 0

    @Volatile
    var activeSpeakerLabel: String = "Speaker 1 (Journalist)"
        private set

    fun reset() {
        synchronized(this) {
            speakerCentroids.clear()
            speakerCounts.clear()
            currentUtteranceVectors.clear()
            currentRmsValues.clear()
            lastUtteranceEndMs = 0L
            currentSpeakerIndex = 0
            activeSpeakerLabel = formatSpeaker(0)
        }
    }

    private fun formatSpeaker(index: Int): String {
        return when (index) {
            0 -> "Speaker 1 (Journalist)"
            1 -> "Speaker 2 (Interviewee)"
            else -> "Speaker ${index + 1}"
        }
    }

    /** Feed RMS dB frame from Android SpeechRecognizer.onRmsChanged */
    fun processRmsFrame(rmsdB: Float) {
        if (rmsdB < 1.5f) return
        synchronized(this) {
            currentRmsValues.add(rmsdB.toDouble())
        }
    }

    /** Feed raw 16-bit little-endian PCM bytes at 16kHz. */
    fun processPcmChunk(pcmBytes: ByteArray) {
        if (pcmBytes.size < 640) return
        val shortCount = pcmBytes.size / 2
        val samples = ShortArray(shortCount)
        ByteBuffer.wrap(pcmBytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)

        var sumSq = 0.0
        for (s in samples) {
            val norm = s / 32768.0
            sumSq += norm * norm
        }
        val rms = sqrt(sumSq / shortCount)
        if (rms < 0.015) return

        val features = extractVoiceEmbedding(samples, rms)
        synchronized(this) {
            currentUtteranceVectors.add(features)
            if (currentUtteranceVectors.size >= 6) {
                activeSpeakerLabel = assignOrUpdateCluster(averageVectors(currentUtteranceVectors))
            }
        }
    }

    /** Finalize speaker assignment at the end of a recognized utterance. */
    fun finalizeUtteranceSpeaker(): String {
        synchronized(this) {
            val now = System.currentTimeMillis()
            val gapMs = if (lastUtteranceEndMs > 0L) (now - lastUtteranceEndMs) else 0L
            lastUtteranceEndMs = now

            if (currentUtteranceVectors.isNotEmpty()) {
                val avg = averageVectors(currentUtteranceVectors)
                activeSpeakerLabel = assignOrUpdateCluster(avg)
                currentUtteranceVectors.clear()
                currentRmsValues.clear()
                return activeSpeakerLabel
            }

            // When using Android SpeechRecognizer RMS stream, combine vocal energy profile + conversational turn gap
            if (currentRmsValues.isNotEmpty()) {
                val meanRms = currentRmsValues.average()
                var variance = 0.0
                for (r in currentRmsValues) {
                    variance += (r - meanRms) * (r - meanRms)
                }
                val stdRms = sqrt(variance / currentRmsValues.size)
                val pseudoEmbedding = l2Normalize(
                    doubleArrayOf(
                        meanRms / 12.0,
                        stdRms / 5.0,
                        ln(currentRmsValues.size.toDouble() + 1.0) * 0.3,
                        1.0
                    )
                )
                currentRmsValues.clear()

                // If there was a natural conversational pause (> 1400ms) and energy profile shifted, switch speaker
                if (gapMs > 1400L && speakerCentroids.isNotEmpty()) {
                    val prevCentroid = speakerCentroids[currentSpeakerIndex]
                    val sim = cosineSimilarity(pseudoEmbedding, prevCentroid)
                    if (sim < 0.96) {
                        currentSpeakerIndex = (currentSpeakerIndex + 1) % maxSpeakers
                    }
                }
                if (speakerCentroids.size <= currentSpeakerIndex) {
                    speakerCentroids.add(pseudoEmbedding)
                    speakerCounts.add(1)
                } else {
                    speakerCentroids[currentSpeakerIndex] = pseudoEmbedding
                }
                activeSpeakerLabel = formatSpeaker(currentSpeakerIndex)
            } else if (gapMs > 2200L) {
                currentSpeakerIndex = (currentSpeakerIndex + 1) % maxSpeakers
                activeSpeakerLabel = formatSpeaker(currentSpeakerIndex)
            }

            return activeSpeakerLabel
        }
    }

    private fun extractVoiceEmbedding(samples: ShortArray, rms: Double): DoubleArray {
        val n = samples.size
        var zeroCrossings = 0
        for (i in 1 until n) {
            if ((samples[i - 1] >= 0 && samples[i] < 0) || (samples[i - 1] < 0 && samples[i] >= 0)) {
                zeroCrossings++
            }
        }
        val zcr = zeroCrossings.toDouble() / n

        val minLag = sampleRate / 350
        val maxLag = minOf(sampleRate / 75, n / 2)
        var bestLag = minLag
        var maxCorr = -1.0
        val window = minOf(n - maxLag, 512)
        if (window > 64) {
            for (lag in minLag..maxLag) {
                var corr = 0.0
                for (i in 0 until window) {
                    corr += (samples[i] / 32768.0) * (samples[i + lag] / 32768.0)
                }
                if (corr > maxCorr) {
                    maxCorr = corr
                    bestLag = lag
                }
            }
        }
        val pitchHz = sampleRate.toDouble() / max(bestLag, 1)
        val normPitch = (pitchHz - 75.0) / 275.0

        var diffEnergy = 0.0
        var lowPassEnergy = 0.0
        var prev = samples[0] / 32768.0
        var lp = prev
        for (i in 1 until n) {
            val cur = samples[i] / 32768.0
            val diff = cur - prev
            lp = 0.85 * lp + 0.15 * cur
            diffEnergy += diff * diff
            lowPassEnergy += lp * lp
            prev = cur
        }
        val spectralRatio = ln((diffEnergy + 1e-6) / (lowPassEnergy + 1e-6))

        val vec = doubleArrayOf(
            normPitch * 2.2,
            zcr * 3.0,
            spectralRatio * 0.4,
            ln(rms + 1e-4) * 0.15
        )
        return l2Normalize(vec)
    }

    private fun assignOrUpdateCluster(embedding: DoubleArray): String {
        if (speakerCentroids.isEmpty()) {
            speakerCentroids.add(embedding)
            speakerCounts.add(1)
            currentSpeakerIndex = 0
            return formatSpeaker(0)
        }

        var bestIdx = 0
        var bestSim = -1.0
        for (i in speakerCentroids.indices) {
            val sim = cosineSimilarity(embedding, speakerCentroids[i])
            if (sim > bestSim) {
                bestSim = sim
                bestIdx = i
            }
        }

        return if (bestSim >= similarityThreshold || speakerCentroids.size >= maxSpeakers) {
            val count = speakerCounts[bestIdx] + 1
            val weightNew = 1.0 / minOf(count, 25)
            val updated = DoubleArray(embedding.size) { d ->
                speakerCentroids[bestIdx][d] * (1.0 - weightNew) + embedding[d] * weightNew
            }
            speakerCentroids[bestIdx] = l2Normalize(updated)
            speakerCounts[bestIdx] = count
            currentSpeakerIndex = bestIdx
            formatSpeaker(bestIdx)
        } else {
            speakerCentroids.add(embedding)
            speakerCounts.add(1)
            currentSpeakerIndex = speakerCentroids.size - 1
            formatSpeaker(currentSpeakerIndex)
        }
    }

    private fun averageVectors(vectors: List<DoubleArray>): DoubleArray {
        val dim = vectors.first().size
        val sum = DoubleArray(dim)
        for (v in vectors) {
            for (i in 0 until dim) sum[i] += v[i]
        }
        return l2Normalize(sum)
    }

    private fun cosineSimilarity(a: DoubleArray, b: DoubleArray): Double {
        var dot = 0.0
        for (i in a.indices) dot += a[i] * b[i]
        return dot
    }

    private fun l2Normalize(v: DoubleArray): DoubleArray {
        var norm = 0.0
        for (x in v) norm += x * x
        norm = sqrt(max(norm, 1e-12))
        return DoubleArray(v.size) { i -> v[i] / norm }
    }
}
