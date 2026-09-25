package com.protosync.scaffold

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

/** Compose 工具链冒烟工程:能 assembleDebug 即证明 AGP+Kotlin+Compose 全链路可用。 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { ScaffoldApp() }
    }
}

@Composable
fun ScaffoldApp() {
    MaterialTheme {
        Text(text = "ProtoSync Compose toolchain OK")
    }
}
