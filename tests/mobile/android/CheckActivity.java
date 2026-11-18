package hxn.assets.test;
import android.app.Activity;
import android.os.Bundle;
public final class CheckActivity extends Activity {
    static { System.loadLibrary("hxn_asset_check"); }
    private static final java.util.concurrent.atomic.AtomicBoolean started = new java.util.concurrent.atomic.AtomicBoolean();
    private static native void runCheck(android.content.Context context, boolean remote);
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        final boolean remote = getIntent().getBooleanExtra("remote", false);
        if (started.compareAndSet(false, true)) new Thread(new Runnable() {
            @Override public void run() {
                runCheck(getApplicationContext(), remote);
                runOnUiThread(new Runnable() { @Override public void run() { finish(); } });
            }
        }, "asset-test").start();
    }
}
