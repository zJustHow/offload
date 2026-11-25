import Accelerate
import Foundation

/// Exact (brute-force) cosine search over normalized vectors, using one matrix-vector product per
/// embedding space. At personal-data scale (tens to a few hundred thousand chunks) this is a few
/// milliseconds with Accelerate and avoids the recall loss, build time and tuning of an ANN index.
public final class VectorIndex: @unchecked Sendable {
    public enum Target: Sendable { case chunks, notes }

    private struct Matrix {
        let dim: Int
        var chunkKeys: [Int64] = []
        var noteKeys: [String] = []
        var data: [Float] = []
        var rows: Int { dim == 0 ? 0 : data.count / dim }
    }

    private let store: KnowledgeStore
    private let lock = NSLock()
    private var generation = -1
    private var chunkMatrices: [String: Matrix] = [:]
    private var noteMatrices: [String: Matrix] = [:]

    public init(store: KnowledgeStore) { self.store = store }

    /// Top-`k` rows of the given space by cosine similarity (vectors are pre-normalized, so the
    /// dot product is the cosine). Returns keys with scores, best first.
    public func searchChunks(_ query: EmbeddedVector, k: Int) throws -> [(id: Int64, score: Float)] {
        try refreshIfNeeded()
        lock.lock(); defer { lock.unlock() }
        guard let m = chunkMatrices[query.space], m.dim == query.values.count else { return [] }
        return topK(m, query.values, k).map { (m.chunkKeys[$0.row], $0.score) }
    }

    public func searchNotes(_ query: EmbeddedVector, k: Int) throws -> [(path: String, score: Float)] {
        try refreshIfNeeded()
        lock.lock(); defer { lock.unlock() }
        guard let m = noteMatrices[query.space], m.dim == query.values.count else { return [] }
        return topK(m, query.values, k).map { (m.noteKeys[$0.row], $0.score) }
    }

    private func refreshIfNeeded() throws {
        let current = store.vectorGeneration
        lock.lock()
        let stale = generation != current
        lock.unlock()
        guard stale else { return }

        var newChunks: [String: Matrix] = [:]
        for space in try store.chunkVectorSpaces() {
            let rows = try store.allChunkVectors(space: space)
            guard let dim = rows.first?.values.count, dim > 0 else { continue }
            var m = Matrix(dim: dim)
            m.data.reserveCapacity(rows.count * dim)
            for r in rows where r.values.count == dim { m.chunkKeys.append(r.id); m.data.append(contentsOf: r.values) }
            newChunks[space] = m
        }
        var newNotes: [String: Matrix] = [:]
        for space in try store.noteVectorSpaces() {
            let rows = try store.allNoteVectors(space: space)
            guard let dim = rows.first?.values.count, dim > 0 else { continue }
            var m = Matrix(dim: dim)
            for r in rows where r.values.count == dim { m.noteKeys.append(r.path); m.data.append(contentsOf: r.values) }
            newNotes[space] = m
        }
        lock.lock()
        chunkMatrices = newChunks; noteMatrices = newNotes; generation = current
        lock.unlock()
    }

    private func topK(_ m: Matrix, _ q: [Float], _ k: Int) -> [(row: Int, score: Float)] {
        let rows = m.rows
        guard rows > 0, k > 0 else { return [] }
        var scores = [Float](repeating: 0, count: rows)
        // scores (rows x 1) = data (rows x dim) * q (dim x 1)
        vDSP_mmul(m.data, 1, q, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(m.dim))
        let order = scores.indices.sorted { scores[$0] > scores[$1] }.prefix(k)
        return order.map { ($0, scores[$0]) }
    }
}
