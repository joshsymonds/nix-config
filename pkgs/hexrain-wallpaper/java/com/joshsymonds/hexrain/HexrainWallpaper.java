package com.joshsymonds.hexrain;

import android.graphics.PixelFormat;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLExt;
import android.opengl.EGLSurface;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.service.wallpaper.WallpaperService;
import android.util.Log;
import android.view.Choreographer;
import android.view.SurfaceHolder;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import org.json.JSONException;
import org.json.JSONObject;

/** DMS's hexrain wallpaper as an Android live wallpaper. */
public final class HexrainWallpaper extends WallpaperService {
    private static final String TAG = "hexrain";

    @Override
    public Engine onCreateEngine() {
        return new HexrainEngine();
    }

    /** DMS's wallpaper.json, baked into the APK at build time. */
    private Scene loadScene() throws IOException, JSONException {
        String text;
        try (InputStream in = getAssets().open("scene.json")) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            for (int n; (n = in.read(buf)) > 0; ) {
                out.write(buf, 0, n);
            }
            text = out.toString(StandardCharsets.UTF_8.name());
        }
        JSONObject json = new JSONObject(text);
        JSONObject shader = json.getJSONObject("shader");
        Map<String, float[]> values = new HashMap<>();
        for (Iterator<String> keys = shader.keys(); keys.hasNext(); ) {
            String key = keys.next();
            Object v = shader.get(key);
            if (v instanceof Number) {
                values.put(key, new float[] {((Number) v).floatValue()});
            } else if (v instanceof String && ((String) v).startsWith("#")) {
                int rgb = Integer.parseInt(((String) v).substring(1, 7), 16);
                values.put(key, new float[] {
                    ((rgb >> 16) & 0xff) / 255f, ((rgb >> 8) & 0xff) / 255f, (rgb & 0xff) / 255f, 1f,
                });
            }
        }
        return new Scene(values, json.getJSONObject("harness").optDouble("speed", 1.0));
    }

    /**
     * One wallpaper instance (the home/lock screen, or the picker's preview).
     * Renders on its own thread, 30 frames a second while visible: the field
     * moves slowly, so a higher rate costs battery without showing.
     */
    private final class HexrainEngine extends Engine implements Choreographer.FrameCallback {
        private static final long FRAME_INTERVAL_NS = 1_000_000_000L / 30;
        // A vsync landing a little early still counts as the next 30 Hz frame.
        private static final long FRAME_SLACK_NS = 4_000_000L;

        private final HandlerThread thread = new HandlerThread("hexrain");
        private Handler handler;

        // Everything below is touched only on `thread`.
        private Choreographer choreographer;
        private EGLDisplay display = EGL14.EGL_NO_DISPLAY;
        private EGLConfig config;
        private EGLContext context = EGL14.EGL_NO_CONTEXT;
        private EGLSurface surface = EGL14.EGL_NO_SURFACE;
        private Scene scene;
        private Renderer renderer;
        private boolean visible;
        private boolean frameRequested;
        private long lastFrameNs;

        @Override
        public void onCreate(SurfaceHolder holder) {
            super.onCreate(holder);
            holder.setFormat(PixelFormat.RGBX_8888);
            thread.start();
            handler = new Handler(thread.getLooper());
            runAndWait(() -> {
                choreographer = Choreographer.getInstance();
                try {
                    scene = loadScene();
                } catch (IOException | JSONException e) {
                    throw new IllegalStateException("scene.json", e);
                }
                initEgl();
            });
        }

        @Override
        public void onSurfaceCreated(SurfaceHolder holder) {
            super.onSurfaceCreated(holder);
            runAndWait(() -> createSurface(holder));
        }

        @Override
        public void onSurfaceChanged(SurfaceHolder holder, int format, int width, int height) {
            super.onSurfaceChanged(holder, format, width, height);
            runAndWait(() -> {
                float density = getResources().getDisplayMetrics().density;
                renderer.resize(scene.forScreen(width, height, density), width, height);
                drawFrame();
            });
        }

        @Override
        public void onSurfaceRedrawNeeded(SurfaceHolder holder) {
            super.onSurfaceRedrawNeeded(holder);
            runAndWait(this::drawFrame);
        }

        @Override
        public void onSurfaceDestroyed(SurfaceHolder holder) {
            runAndWait(this::destroySurface);
            super.onSurfaceDestroyed(holder);
        }

        @Override
        public void onVisibilityChanged(boolean visible) {
            handler.post(() -> {
                this.visible = visible;
                requestFrame();
            });
        }

        @Override
        public void onDestroy() {
            runAndWait(this::release);
            thread.quitSafely();
            super.onDestroy();
        }

        @Override
        public void doFrame(long frameTimeNanos) {
            frameRequested = false;
            if (!visible) {
                return;
            }
            if (frameTimeNanos - lastFrameNs >= FRAME_INTERVAL_NS - FRAME_SLACK_NS) {
                lastFrameNs = frameTimeNanos;
                drawFrame();
            }
            requestFrame();
        }

        private void requestFrame() {
            if (visible && !frameRequested && surface != EGL14.EGL_NO_SURFACE) {
                frameRequested = true;
                choreographer.postFrameCallback(this);
            }
        }

        private void initEgl() {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            int[] version = new int[2];
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
                throw new IllegalStateException("eglInitialize: 0x" + Integer.toHexString(EGL14.eglGetError()));
            }
            int[] attribs = {
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_NONE,
            };
            EGLConfig[] configs = new EGLConfig[1];
            int[] count = new int[1];
            if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) || count[0] == 0) {
                throw new IllegalStateException("no GLES 3 window config");
            }
            config = configs[0];
            context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
                new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE}, 0);
            if (context == EGL14.EGL_NO_CONTEXT) {
                throw new IllegalStateException("eglCreateContext: 0x" + Integer.toHexString(EGL14.eglGetError()));
            }
        }

        private void createSurface(SurfaceHolder holder) {
            surface = EGL14.eglCreateWindowSurface(display, config, holder.getSurface(),
                new int[] {EGL14.EGL_NONE}, 0);
            if (surface == EGL14.EGL_NO_SURFACE) {
                throw new IllegalStateException("eglCreateWindowSurface: 0x" + Integer.toHexString(EGL14.eglGetError()));
            }
            EGL14.eglMakeCurrent(display, surface, surface, context);
            if (renderer == null) {
                try {
                    renderer = new Renderer(getAssets());
                } catch (IOException e) {
                    throw new IllegalStateException("shader assets", e);
                }
            }
            requestFrame();
        }

        private void drawFrame() {
            if (surface == EGL14.EGL_NO_SURFACE) {
                return;
            }
            // Scene time runs on the clock since boot, so the field carries on
            // where it was whenever the wallpaper is recreated or shown again.
            renderer.draw(SystemClock.elapsedRealtimeNanos() / 1e9 * scene.timeScale);
            if (!EGL14.eglSwapBuffers(display, surface)) {
                Log.w(TAG, "eglSwapBuffers: 0x" + Integer.toHexString(EGL14.eglGetError()));
            }
        }

        private void destroySurface() {
            if (surface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                EGL14.eglDestroySurface(display, surface);
                surface = EGL14.EGL_NO_SURFACE;
            }
        }

        // Destroying the context frees the renderer's GL objects with it. The
        // display stays initialised: the preview and the wallpaper share this
        // process, and terminating it would pull it from under the other.
        private void release() {
            destroySurface();
            if (context != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(display, context);
                context = EGL14.EGL_NO_CONTEXT;
            }
            renderer = null;
        }

        private void runAndWait(Runnable task) {
            CountDownLatch done = new CountDownLatch(1);
            RuntimeException[] failure = new RuntimeException[1];
            handler.post(() -> {
                try {
                    task.run();
                } catch (RuntimeException e) {
                    failure[0] = e;
                } finally {
                    done.countDown();
                }
            });
            boolean interrupted = false;
            while (true) {
                try {
                    done.await();
                    break;
                } catch (InterruptedException e) {
                    interrupted = true;
                }
            }
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
            if (failure[0] != null) {
                Log.e(TAG, "render thread", failure[0]);
                throw failure[0];
            }
        }
    }
}
