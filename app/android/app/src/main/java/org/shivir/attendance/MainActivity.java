package org.shivir.attendance;

import android.Manifest;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowManager;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.getcapacitor.BridgeActivity;

/**
 * The web app is unchanged -- this shell exists for two things the browser
 * cannot give us on a shared volunteer handset.
 *
 * 1. The camera permission. Capacitor's WebView only grants getUserMedia once
 *    the app itself holds CAMERA, and on Android 6+ that has to be asked for
 *    at runtime. Asking on launch means the volunteer answers one dialog at
 *    base camp instead of a permission prompt in front of a queue.
 *
 * 2. Keeping the screen awake. A scanning lane runs for an hour at a time and
 *    a phone that sleeps between arrivals costs several seconds per wake.
 */
public class MainActivity extends BridgeActivity {

    private static final int CAMERA_REQUEST = 4711;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                && ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                   != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(
                    this, new String[]{Manifest.permission.CAMERA}, CAMERA_REQUEST);
        }
    }
}
