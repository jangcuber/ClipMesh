package dev.clipmesh.android

import java.util.concurrent.atomic.AtomicLong

/** Counts only; clipboard bytes, URIs and exception details are never exposed. */
object BridgeDiagnostics {
    val imagesCaptured=AtomicLong()
    val imagesReceived=AtomicLong()
    val imagesRejected=AtomicLong()
    val uriGrantFailures=AtomicLong()
    fun summary()="Images: captured ${imagesCaptured.get()} · received ${imagesReceived.get()} · rejected ${imagesRejected.get()} · hook errors ${uriGrantFailures.get()}"
}
