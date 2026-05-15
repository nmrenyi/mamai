package com.example.app

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log

/**
 * Thin launcher for [BenchmarkForegroundService].
 *
 * All benchmark logic lives in the service so it survives screen-off and
 * device-lock — vendor power managers (OPPO, Xiaomi, Huawei) will idle a
 * plain Activity but respect a foreground service with a sticky
 * notification.
 *
 * Launch via ADB exactly as before — the Activity forwards all extras
 * straight to the service, then finishes immediately:
 *
 *   adb shell am start -n com.example.app/.BenchmarkActivity \
 *       --ei repeats 3 --el cooldown_ms 5000
 *
 * Optional extras:
 *   --ez skip_retrieval true     Skip RAG retrieval (generation only)
 *   --ez rag_only true           Skip the No-RAG mode (k-sweep helper).
 *                                Mutually exclusive with skip_retrieval —
 *                                if both are set, skip_retrieval wins.
 *   --es query_filter short      Filter by category or specific query ID
 *   --ei retrieve_k N            Override retrieval top_k for this session.
 *                                Pass any value >= 0 to override; pass -1
 *                                (or omit) to use runtime_config.json's
 *                                value. The activity normalises -1 to null
 *                                before forwarding to the service.
 */
class BenchmarkActivity : Activity() {

    companion object {
        private const val BENCH_TAG = "mam-ai-bench"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val serviceIntent = Intent(this, BenchmarkForegroundService::class.java).apply {
            // Forward every extra the user might have passed via `am start`.
            // Defaults are resolved inside the service.
            if (intent.hasExtra("repeats"))
                putExtra("repeats", intent.getIntExtra("repeats", 3))
            if (intent.hasExtra("cooldown_ms"))
                putExtra("cooldown_ms", intent.getLongExtra("cooldown_ms", 5000L))
            if (intent.hasExtra("skip_retrieval"))
                putExtra("skip_retrieval", intent.getBooleanExtra("skip_retrieval", false))
            if (intent.hasExtra("rag_only"))
                putExtra("rag_only", intent.getBooleanExtra("rag_only", false))
            if (intent.hasExtra("query_filter"))
                putExtra("query_filter", intent.getStringExtra("query_filter"))
            if (intent.hasExtra("retrieve_k"))
                putExtra("retrieve_k", intent.getIntExtra("retrieve_k", -1))
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
        Log.w(BENCH_TAG, "[BENCHMARK] BenchmarkActivity → forwarded extras to BenchmarkForegroundService, finishing.")
        finish()
    }
}
