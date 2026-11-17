/* gl-probe — headless proof that a GPU actually EXECUTES, not just that a
 * driver/context exists. Compiles a vertex+fragment shader, draws a triangle
 * into an FBO on the EGL surfaceless platform, and reads the centre pixel back.
 *
 * Compile:
 *   gcc -O1 gl-probe.c -o gl-probe $(pkg-config --cflags --libs egl glesv2)
 *
 * Run against a LOCAL Mesa build without touching the system one:
 *   EGL_PLATFORM=surfaceless LIBGL_DRIVERS_PATH=<build>/src/gallium/targets/dril \
 *     meson devenv -C build /abs/path/to/gl-probe
 * (meson devenv sets LD_LIBRARY_PATH and __EGL_VENDOR_LIBRARY_FILENAMES; it also
 *  runs from the build dir, so the probe path must be absolute.)
 *
 * Exit 0 = the GPU drew the triangle. Non-zero = read the printed stage.
 *
 * Notes learned the hard way:
 *  - surfaceless needs a surface type in eglChooseConfig (PBUFFER_BIT first,
 *    then a bare EGL_NONE list) or it returns 0 configs with EGL_SUCCESS.
 *  - GLES2 has no GL_RGBA8 (ES3 token); GL_RGBA4 is a valid ES2 renderbuffer
 *    format and round-trips exact 0/255 values.
 */
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <stdio.h>

static const char *vs_src =
    "attribute vec2 p;\n"
    "void main() { gl_Position = vec4(p, 0.0, 1.0); }\n";
static const char *fs_src =
    "precision mediump float;\n"
    "void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }\n";

int main(void)
{
    EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (dpy == EGL_NO_DISPLAY) { printf("FAIL: eglGetDisplay\n"); return 1; }

    EGLint major, minor;
    if (!eglInitialize(dpy, &major, &minor)) {
        printf("FAIL: eglInitialize 0x%x\n", eglGetError()); return 1;
    }
    printf("EGL %d.%d vendor=%s\n", major, minor,
           eglQueryString(dpy, EGL_VENDOR));

    EGLint cfg_attr[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                          EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                          EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE };
    EGLConfig cfg; EGLint n = 0;
    if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n) || n < 1) {
        EGLint any_attr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
        n = 0;
        if (!eglChooseConfig(dpy, any_attr, &cfg, 1, &n) || n < 1) {
            EGLint bare[] = { EGL_NONE };
            n = 0;
            if (!eglChooseConfig(dpy, bare, &cfg, 1, &n) || n < 1) {
                printf("FAIL: eglChooseConfig (n=%d) 0x%x\n", n, eglGetError());
                return 1;
            }
        }
    }

    EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
    if (ctx == EGL_NO_CONTEXT) {
        printf("FAIL: eglCreateContext 0x%x\n", eglGetError()); return 1;
    }
    if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
        printf("FAIL: eglMakeCurrent 0x%x\n", eglGetError()); return 1;
    }

    printf("GL_RENDERER = %s\n", glGetString(GL_RENDERER));
    printf("GL_VERSION  = %s\n", glGetString(GL_VERSION));
    printf("GL_VENDOR   = %s\n", glGetString(GL_VENDOR));

    GLuint fbo, rb;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glGenRenderbuffers(1, &rb);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA4, 64, 64);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_RENDERBUFFER, rb);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        printf("FAIL: FBO incomplete\n"); return 1;
    }

    glViewport(0, 0, 64, 64);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    GLuint v = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(v, 1, &vs_src, NULL); glCompileShader(v);
    GLuint f = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(f, 1, &fs_src, NULL); glCompileShader(f);

    GLint ok = 0;
    glGetShaderiv(v, GL_COMPILE_STATUS, &ok);
    if (!ok) { char l[512]; glGetShaderInfoLog(v, 512, NULL, l);
               printf("FAIL: vertex shader: %s\n", l); return 1; }
    glGetShaderiv(f, GL_COMPILE_STATUS, &ok);
    if (!ok) { char l[512]; glGetShaderInfoLog(f, 512, NULL, l);
               printf("FAIL: fragment shader: %s\n", l); return 1; }

    GLuint pr = glCreateProgram();
    glAttachShader(pr, v); glAttachShader(pr, f); glLinkProgram(pr);
    glGetProgramiv(pr, GL_LINK_STATUS, &ok);
    if (!ok) { printf("FAIL: link\n"); return 1; }
    glUseProgram(pr);

    GLint loc = glGetAttribLocation(pr, "p");
    if (loc < 0) loc = 0;
    static const float tri[] = { -1.0f, -1.0f,  3.0f, -1.0f,  -1.0f, 3.0f };
    glVertexAttribPointer(loc, 2, GL_FLOAT, GL_FALSE, 0, tri);
    glEnableVertexAttribArray(loc);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();

    unsigned char px[4] = { 0, 0, 0, 0 };
    glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    printf("pixel@32,32 = rgba(%d,%d,%d,%d)  glerr=0x%x\n",
           px[0], px[1], px[2], px[3], glGetError());

    if (px[1] > 200 && px[0] < 60) {
        printf("RESULT: PASS - GPU drew the triangle\n");
        return 0;
    }
    printf("RESULT: FAIL - unexpected pixel\n");
    return 1;
}
