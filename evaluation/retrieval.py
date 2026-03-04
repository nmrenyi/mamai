"""
Vector store reader and retrieval for RAG evaluation.

Reads pre-computed Gecko embeddings from the app's SQLite database and provides
cosine similarity search for query embedding vectors.
"""

import sqlite3
import struct

import numpy as np


def load_vector_store(db_path: str) -> list[tuple[str, np.ndarray]]:
    """Load chunks + embeddings from the app's SQLite vector store.

    The embeddings are stored as blobs: 4-byte "VF32" header + 768 float32 values.

    Returns:
        List of (text, embedding_array) tuples.
    """
    conn = sqlite3.connect(db_path)
    rows = conn.execute("SELECT text, embeddings FROM rag_vector_store").fetchall()
    conn.close()

    store = []
    for text, blob in rows:
        # Skip 4-byte "VF32" header, unpack remaining as float32
        n_floats = (len(blob) - 4) // 4
        embedding = np.array(struct.unpack(f"{n_floats}f", blob[4:]), dtype=np.float32)
        store.append((text, embedding))

    print(f"Loaded {len(store)} chunks from {db_path} (dim={store[0][1].shape[0]})")
    return store


def build_index(store: list[tuple[str, np.ndarray]]) -> tuple[list[str], np.ndarray]:
    """Build a normalized embedding matrix for fast cosine similarity.

    Returns:
        (texts, normed_matrix) where normed_matrix is (n_chunks, dim).
    """
    texts = [t for t, _ in store]
    matrix = np.stack([e for _, e in store])
    # L2-normalize each row for cosine similarity via dot product
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    normed = matrix / norms
    return texts, normed


def retrieve(query_embedding: np.ndarray, texts: list[str], normed_matrix: np.ndarray,
             top_k: int = 3) -> list[tuple[str, float]]:
    """Cosine similarity search.

    Args:
        query_embedding: 768-dim query vector (unnormalized is fine).
        texts: List of chunk texts.
        normed_matrix: Pre-normalized (n_chunks, dim) matrix.
        top_k: Number of results to return.

    Returns:
        List of (chunk_text, similarity_score) tuples, highest first.
    """
    q = query_embedding / (np.linalg.norm(query_embedding) + 1e-10)
    similarities = normed_matrix @ q
    top_indices = np.argsort(similarities)[-top_k:][::-1]
    return [(texts[i], float(similarities[i])) for i in top_indices]


class GeckoEmbedder:
    """Gecko TFLite embedding model for query encoding.

    Replicates the on-device Gecko embedding pipeline from RagPipeline.kt.
    """

    def __init__(self, model_path: str, tokenizer_path: str):
        import sentencepiece as spm
        try:
            from ai_edge_litert import interpreter as tflite
        except ImportError:
            try:
                import tflite_runtime.interpreter as tflite
            except ImportError:
                import tensorflow as tf
                tflite = tf.lite

        print(f"Loading Gecko model: {model_path}")
        self.interpreter = tflite.Interpreter(model_path=model_path, num_threads=4)
        self.interpreter.allocate_tensors()
        self.input_details = self.interpreter.get_input_details()
        self.output_details = self.interpreter.get_output_details()

        self.tokenizer = spm.SentencePieceProcessor()
        self.tokenizer.Load(tokenizer_path)

        self.max_length = self.input_details[0]['shape'][1]
        dim = self.output_details[0]['shape'][-1]
        print(f"Gecko loaded: max_tokens={self.max_length}, dim={dim}")

    def embed(self, text: str) -> np.ndarray:
        """Embed a single text string. Returns 768-dim float32 array."""
        token_ids = self.tokenizer.encode_as_ids(text)
        if len(token_ids) > self.max_length:
            token_ids = token_ids[:self.max_length]
        else:
            token_ids = token_ids + [0] * (self.max_length - len(token_ids))

        input_tensor = np.array([token_ids], dtype=np.int32)
        self.interpreter.set_tensor(self.input_details[0]['index'], input_tensor)
        self.interpreter.invoke()
        embedding = self.interpreter.get_tensor(self.output_details[0]['index'])
        return embedding.flatten().astype(np.float32)
