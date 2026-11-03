package com.apexarena.app;

import android.os.Bundle;
import android.webkit.WebView;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // v33: системный «размер шрифта» Android не должен раздувать интерфейс (из-за него всё вылезало за края)
        try {
            WebView wv = getBridge().getWebView();
            wv.getSettings().setTextZoom(100);
        } catch (Exception ignored) {}
    }
}
