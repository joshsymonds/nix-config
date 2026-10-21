package com.joshsymonds.hexrain;

import android.content.res.AssetManager;
import android.opengl.GLES30;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * DMS's three-pass hexrain renderer, wired as quickshell/Widgets/
 * HexrainEffect.qml wires it: each frame the cell pass and the light pass
 * render into textures, then the main pass samples both and draws the
 * screen. The shaders are DMS's own, compiled to GLSL ES 300 by qsb at
 * build time (assets/*.frag). Needs a current GLES 3 context on every call.
 */
final class Renderer {
    // Full-screen triangle. Into the pre-pass textures, qt_TexCoord0 row 0 is
    // texture row 0 (what the main pass samples); on screen, qt_TexCoord0
    // runs top-down as in a Qt item.
    private static final String TEXTURE_VERTEX = vertex("p.y");
    private static final String SCREEN_VERTEX = vertex("1.0 - p.y");

    private static String vertex(String y) {
        return "#version 300 es\n"
            + "out vec2 qt_TexCoord0;\n"
            + "void main() {\n"
            + "    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
            + "    qt_TexCoord0 = vec2(p.x, " + y + ");\n"
            + "    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
            + "}\n";
    }

    private final Pass cells;
    private final Pass light;
    private final Pass main;
    private final int vertexArray;
    // The cell data (heights, orientations, reach) wants full float; half
    // float is the fallback where float32 isn't colour-renderable.
    private final int cellFormat;

    private Scene scene;
    private HexrainGrid grid;
    private int width;
    private int height;
    private Target cellTarget;
    private Target lightTarget;

    Renderer(AssetManager assets) throws IOException {
        cells = new Pass(TEXTURE_VERTEX, read(assets, "chrome_hexrain_cells.frag"));
        light = new Pass(TEXTURE_VERTEX, read(assets, "chrome_hexrain_light.frag"));
        main = new Pass(SCREEN_VERTEX, read(assets, "chrome_hexrain.frag"));
        int[] ids = new int[1];
        GLES30.glGenVertexArrays(1, ids, 0);
        vertexArray = ids[0];
        String extensions = GLES30.glGetString(GLES30.GL_EXTENSIONS);
        cellFormat = extensions != null && extensions.contains("GL_EXT_color_buffer_float")
            ? GLES30.GL_RGBA32F : GLES30.GL_RGBA16F;
    }

    /** Sizes the pre-pass textures for a `width` × `height` screen showing `scene`. */
    void resize(Scene scene, int width, int height) {
        this.scene = scene;
        this.width = width;
        this.height = height;
        grid = new HexrainGrid((float) scene.get("cellSize"), width, height);
        if (cellTarget != null) {
            cellTarget.release();
            lightTarget.release();
        }
        cellTarget = new Target(grid.cols * HexrainGrid.CELL_TEXELS, grid.rows, cellFormat, GLES30.GL_NEAREST);
        lightTarget = new Target(grid.lightCols * HexrainGrid.LIGHT_BLOCKS, grid.lightRows,
                                 GLES30.GL_RGBA16F, GLES30.GL_LINEAR);
    }

    /** Draws the frame at scene time `t` (seconds) into the current surface. */
    void draw(double t) {
        Map<String, float[]> values = scene.frame(grid, t);

        GLES30.glDisable(GLES30.GL_BLEND);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        GLES30.glBindVertexArray(vertexArray);

        cellTarget.bind();
        cells.run(values);
        lightTarget.bind();
        light.run(values);

        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0);
        GLES30.glViewport(0, 0, width, height);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, cellTarget.texture);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE2);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, lightTarget.texture);
        main.use();
        main.sampler("cellTex", 1);
        main.sampler("lightTex", 2);
        main.run(values);
    }

    private static String read(AssetManager assets, String name) throws IOException {
        try (InputStream in = assets.open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            for (int n; (n = in.read(buf)) > 0; ) {
                out.write(buf, 0, n);
            }
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }

    /** A linked program and its active uniforms (qsb names the members of DMS's uniform block ubuf.*). */
    private static final class Pass {
        final int program;
        final String[] keys;
        final int[] locations;
        final int[] types;

        Pass(String vertexSource, String fragmentSource) {
            int vertex = compile(GLES30.GL_VERTEX_SHADER, vertexSource);
            int fragment = compile(GLES30.GL_FRAGMENT_SHADER, fragmentSource);
            program = GLES30.glCreateProgram();
            GLES30.glAttachShader(program, vertex);
            GLES30.glAttachShader(program, fragment);
            GLES30.glLinkProgram(program);
            GLES30.glDeleteShader(vertex);
            GLES30.glDeleteShader(fragment);
            int[] status = new int[1];
            GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0);
            if (status[0] == 0) {
                throw new IllegalStateException("link failed: " + GLES30.glGetProgramInfoLog(program));
            }
            int[] count = new int[1];
            GLES30.glGetProgramiv(program, GLES30.GL_ACTIVE_UNIFORMS, count, 0);
            keys = new String[count[0]];
            locations = new int[count[0]];
            types = new int[count[0]];
            int[] size = new int[1];
            int[] type = new int[1];
            for (int u = 0; u < count[0]; u++) {
                String name = GLES30.glGetActiveUniform(program, u, size, 0, type, 0);
                keys[u] = name.startsWith("ubuf.") ? name.substring(5) : name;
                locations[u] = GLES30.glGetUniformLocation(program, name);
                types[u] = type[0];
            }
        }

        private static int compile(int kind, String source) {
            int shader = GLES30.glCreateShader(kind);
            GLES30.glShaderSource(shader, source);
            GLES30.glCompileShader(shader);
            int[] status = new int[1];
            GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0);
            if (status[0] == 0) {
                String log = GLES30.glGetShaderInfoLog(shader);
                GLES30.glDeleteShader(shader);
                throw new IllegalStateException("compile failed: " + log);
            }
            return shader;
        }

        void use() {
            GLES30.glUseProgram(program);
        }

        void sampler(String name, int unit) {
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program, name), unit);
        }

        /** Uploads every uniform `values` has and draws the full-screen triangle. */
        void run(Map<String, float[]> values) {
            use();
            for (int u = 0; u < keys.length; u++) {
                float[] v = values.get(keys[u]);
                if (v == null) {
                    continue;
                }
                switch (types[u]) {
                    case GLES30.GL_FLOAT:
                        GLES30.glUniform1f(locations[u], v[0]);
                        break;
                    case GLES30.GL_FLOAT_VEC3:
                        GLES30.glUniform3f(locations[u], v[0], v[1], v[2]);
                        break;
                    case GLES30.GL_FLOAT_VEC4:
                        GLES30.glUniform4f(locations[u], v[0], v[1], v[2], v[3]);
                        break;
                    case GLES30.GL_FLOAT_MAT4:
                        GLES30.glUniformMatrix4fv(locations[u], 1, false, v, 0);
                        break;
                    default:
                        break;
                }
            }
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        }
    }

    /** A texture with a framebuffer rendering into it. */
    private static final class Target {
        final int texture;
        final int framebuffer;
        final int width;
        final int height;

        Target(int width, int height, int format, int filter) {
            this.width = width;
            this.height = height;
            int[] ids = new int[1];
            GLES30.glGenTextures(1, ids, 0);
            texture = ids[0];
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture);
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, format, width, height);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, filter);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, filter);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
            GLES30.glGenFramebuffers(1, ids, 0);
            framebuffer = ids[0];
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer);
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                                          GLES30.GL_TEXTURE_2D, texture, 0);
            int status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER);
            if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
                throw new IllegalStateException("framebuffer incomplete: 0x" + Integer.toHexString(status));
            }
        }

        void bind() {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer);
            GLES30.glViewport(0, 0, width, height);
        }

        void release() {
            GLES30.glDeleteFramebuffers(1, new int[] {framebuffer}, 0);
            GLES30.glDeleteTextures(1, new int[] {texture}, 0);
        }
    }
}
