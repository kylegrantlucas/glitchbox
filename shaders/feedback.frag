// videobed — default shader for `shader-feedback`.
//
// Driven entirely by uniforms the driver script feeds on stdin, so that frame
// content is a pure function of (seed, frame) and never of wall-clock time.
// Deliberately does NOT read u_time: u_time is wall-clock-ish and would make
// output depend on how fast the machine renders.

#ifdef GL_ES
precision mediump float;
#endif

uniform vec2  u_resolution;
uniform sampler2D u_buffer0;

uniform float u_seed;    // pinned by the pipeline, logged in the manifest
uniform float u_frame;   // integer frame index, fed per frame
uniform float u_amount;  // displacement strength
uniform float u_decay;   // feedback persistence, 0..1

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 st = gl_FragCoord.xy / u_resolution.xy;

    float t = u_frame * 0.05;
    vec2 warp = vec2(
        sin(st.y * 12.0 + t + u_seed) * u_amount,
        cos(st.x *  9.0 - t + u_seed) * u_amount
    ) / u_resolution.xy * 40.0;

    vec3 prev = texture2D(u_buffer0, st + warp).rgb;

    float n = hash(floor(gl_FragCoord.xy * 0.25) + vec2(u_frame, u_seed));
    vec3 src = vec3(
        0.5 + 0.5 * sin(st.x * 6.0 + u_seed),
        0.5 + 0.5 * sin(st.y * 5.0 - u_seed),
        n
    );

    gl_FragColor = vec4(mix(src, prev, u_decay), 1.0);
}
