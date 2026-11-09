package com.example.gemini_live_interview

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Lightweight on-device acoustic speaker diarizer for 16kHz 16-bit mono PCM streams.
 * Extracts normalized voice embeddings (pitch F0, ZCR, low/high band energy ratio, RMS dynamics)
 * over voiced frames and clusters speakers online via cosine similarity.
 */
class SpeakerDiarizer(
    private val sampleRate: Int = 16000,
    private val maxSpeakers: Int = 4,
    private val similarityThreshold: Double = 0.90
) {
    private val speakerCentroids = mutableListOf<DoubleArray>()
    private val speakerCounts = mutableListOf<Int>()
    private val currentUtteranceVectors = mutableListOf<DoubleArray>()

    @Volatile
    var activeSpeakerLabel: String = "Speaker 1"
        private set

    fun reset() {
        synchronized(this) {
            speakerCentroids.clear()
            speakerCounts.clear()
            currentUtteranceVectors.clear()
            activeSpeakerLabel = "Speaker 1"
        }
    }

    /** Feed raw 16-bit little-endian PCM bytes at 16kHz. */
    fun processPcmChunk(pcmBytes: ByteArray) {
        if (pcmBytes.size < 640) return // Minimum 20ms at 16kHz
        val shortCount = pcmBytes.size / 2
        val samples = ShortArray(shortCount)
        ByteBuffer.wrap(pcmBytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)

        // Compute RMS to check Voice Activity (VAD)
        var sumSq = 0.0
        for (s in samples) {
            val norm = s / 32768.0
            sumSq += norm * norm
        }
        val rms = sqrt(sumSq / shortCount)
        if (rms < 0.015) return // Ignore silence / background noise

        val features = extractVoiceEmbedding(samples, rms)
        synchronized(this) {
            currentUtteranceVectors.add(features)
            if (currentUtteranceVectors.size >= 6) {
                activeSpeakerLabel = assignOrUpdateCluster(averageVectors(currentUtteranceVectors))
            }
        }
    }

    /** Finalize speaker assignment at the end of a recognized phrase and clear utterance buffer. */
    fun finalizeUtteranceSpeaker(): String {
        synchronized(this) {
            if (currentUtteranceVectors.isNotEmpty()) {
                val avg = averageVectors(currentUtteranceVectors)
                activeSpeakerLabel = assignOrUpdateCluster(avg)
                currentUtteranceVectors.clear()
            }
            return activeSpeakerLabel
        }
    }

    private fun extractVoiceEmbedding(samples: ShortArray, rms: Double): DoubleArray {
        val n = samples.size
        // 1. Zero-Crossing Rate (correlates with fricatives & vocal tract timbre)
        var zeroCrossings = 0
        for (i in 1 until n) {
            if ((samples[i - 1] >= 0 && samples[i] < 0) || (samples[i - 1] < 0 && samples[i] >= 0)) {
                zeroCrossings++
            }
        }
        val zcr = zeroCrossings.toDouble() / n

        // 2. Fundamental Pitch (F0) via time-domain autocorrelation (75 Hz - 350 Hz)
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
        val normPitch = (pitchHz - 75.0) / 275.0 // Normalized ~[0, 1]

        // 3. First-difference high-frequency vs low-frequency energy balance (spectral tilt)
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
            return "Speaker 1"
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
            "Speaker ${bestIdx + 1}"
        } else {
            speakerCentroids.add(embedding)
            speakerCounts.add(1)
            "Speaker ${speakerCentroids.size}"
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
