# glslViewer under a virtual X server, for `shader-feedback` on headless boxes.
#
# x86_64-linux only. glslviewer is marked broken on aarch64-darwin in nixpkgs
# ("never built on aarch64-darwin since first introduction"), and its inputs are
# X11-only, so there is no Darwin story here to wrap.
#
# --headless is NOT display-free: on the GLFW path it is just
#   glfwWindowHint(GLFW_VISIBLE, GL_FALSE)
# i.e. a hidden window that still needs a display connection. (The genuinely
# display-free backend is EGL/GBM, which targets DRM devices.) On a headless
# render box that means an X server has to exist, hence xvfb-run.
#
# OSC needs no special handling: SUPPORT_OSC is compiled in unconditionally for
# all non-Emscripten builds via the vendored deps/liblo submodule, and nixpkgs
# already sets fetchSubmodules = true.
{ writeShellApplication
, glslviewer
, xvfb-run
}:
writeShellApplication {
  name = "glslviewer-headless";
  runtimeInputs = [ glslviewer xvfb-run ];
  text = ''
    # -a picks a free display number so concurrent renders do not collide.
    exec xvfb-run -a --server-args="-screen 0 ''${VB_GLSL_SCREEN:-1920x1080x24}" \
      glslViewer "$@"
  '';
}
