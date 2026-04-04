#version 320 es

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform vec2 u_touchCenter;
uniform float u_radius;
uniform vec2 u_deformation;
uniform float u_popProgress;
uniform float u_time;

out vec4 frag_color;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float smooth_noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(hash(i + vec2(0.0, 0.0)), hash(i + vec2(1.0, 0.0)), u.x),
    mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

vec4 sample_input(vec2 frag_coord) {
  vec2 uv = frag_coord / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(u_texture, uv);
}

void main() {
  const float THICKNESS_BASE = 300.0;
  const float THICKNESS_GRAVITY = 120.0;
  const float THICKNESS_SWIRL = 100.0;
  const float THICKNESS_DETAIL = 40.0;
  const float COLOR_INTENSITY = 2.0;
  const float EDGE_FADE_END = 0.20;
  const float ENV_REFLECTION_STRENGTH = 0.4;
  const float ENV_BLUR_RADIUS = 50.0;
  const float TWO_PI = 6.28318530718;

  vec2 frag_coord = FlutterFragCoord().xy;
  vec4 raw_background = sample_input(frag_coord);

  if (u_popProgress >= 1.0) {
    frag_color = raw_background;
    return;
  }

  vec2 raw_uv = frag_coord - u_touchCenter;
  float speed = length(u_deformation);
  vec2 move_dir = speed > 0.001 ? normalize(u_deformation) : vec2(0.0, 1.0);

  float parallel_dist = dot(raw_uv, move_dir);
  vec2 perp_vector = raw_uv - (move_dir * parallel_dist);

  float stretch = 1.0 + speed;
  float squash = 1.0 / sqrt(stretch);

  vec2 uv = (move_dir * (parallel_dist / stretch)) + (perp_vector / squash);
  float dist = length(uv);
  float active_radius = u_radius * (1.0 + (u_popProgress * 1.5));

  if (dist >= active_radius) {
    frag_color = raw_background;
    return;
  }

  vec2 n_uv = uv / active_radius;
  float dist_sq = dot(n_uv, n_uv);
  float z = sqrt(max(0.0, 1.0 - dist_sq));
  vec3 normal = normalize(vec3(n_uv, z));
  vec3 view_dir = vec3(0.0, 0.0, 1.0);
  float n_dot_v = max(0.0, dot(normal, view_dir));

  float magnification = 0.45;
  float lens_deform = (1.0 - z) * magnification * (1.0 - u_popProgress);

  vec2 ref_uv_r = frag_coord - (n_uv * active_radius * (lens_deform * 0.88));
  vec2 ref_uv_g = frag_coord - (n_uv * active_radius * (lens_deform * 1.00));
  vec2 ref_uv_b = frag_coord - (n_uv * active_radius * (lens_deform * 1.12));

  vec3 bg_color = vec3(
    sample_input(ref_uv_r).r,
    sample_input(ref_uv_g).g,
    sample_input(ref_uv_b).b
  );

  vec3 reflection_dir = reflect(-view_dir, normal);
  vec3 light_dir_1 = normalize(vec3(0.6, 0.7, 0.8));
  vec3 light_dir_2 = normalize(vec3(-0.5, -0.4, 0.6));

  float light_align_1 = max(0.0, dot(reflection_dir, light_dir_1));
  float light_align_2 = max(0.0, dot(reflection_dir, light_dir_2));

  const float n_film = 1.33;
  const float n_air = 1.0;
  float r0 = pow((n_film - n_air) / (n_film + n_air), 2.0);
  float fresnel = r0 + (1.0 - r0) * pow(1.0 - n_dot_v, 5.0);

  float sin_theta_i = sqrt(max(0.0, 1.0 - (n_dot_v * n_dot_v)));
  float sin_theta_t = sin_theta_i / n_film;
  float cos_theta_t = sqrt(max(0.0, 1.0 - (sin_theta_t * sin_theta_t)));

  float swirl = smooth_noise((n_uv * 3.0) + (u_time * 0.12));
  float thickness_noise = smooth_noise((n_uv * 5.0) - (u_time * 0.08));
  float base_thickness = THICKNESS_BASE + (n_uv.y * THICKNESS_GRAVITY);
  float thickness =
      base_thickness +
      (swirl * THICKNESS_SWIRL) +
      (thickness_noise * THICKNESS_DETAIL);
  thickness = clamp(thickness, 80.0, 900.0);

  float opd = 2.0 * n_film * thickness * cos_theta_t;

  float osc_r = 0.5 + (0.5 * cos(TWO_PI * opd / 650.0));
  float osc_g = 0.5 + (0.5 * cos(TWO_PI * opd / 532.0));
  float osc_b = 0.5 + (0.5 * cos(TWO_PI * opd / 450.0));

  vec3 interference_color = vec3(osc_r, osc_g, osc_b);
  float interference_strength = smoothstep(0.0, EDGE_FADE_END, n_dot_v);

  vec3 film_reflection = interference_color * fresnel * COLOR_INTENSITY;
  vec3 white_reflection = vec3(fresnel);
  vec3 thin_film_color = mix(white_reflection, film_reflection, interference_strength);

  float spec_1 = pow(light_align_1, 250.0) * 2.5;
  float spec_2 = pow(light_align_2, 60.0) * 0.5;
  vec3 highlights = vec3(spec_1 + spec_2);

  vec2 reflect_offset = normal.xy * ENV_BLUR_RADIUS;
  vec2 env_center = frag_coord + reflect_offset;
  float blur_step = ENV_BLUR_RADIUS * 0.4;

  vec3 env_sample =
      (sample_input(env_center).rgb * 0.4) +
      (sample_input(env_center + vec2(blur_step, 0.0)).rgb * 0.15) +
      (sample_input(env_center - vec2(blur_step, 0.0)).rgb * 0.15) +
      (sample_input(env_center + vec2(0.0, blur_step)).rgb * 0.15) +
      (sample_input(env_center - vec2(0.0, blur_step)).rgb * 0.15);

  vec3 env_reflection = env_sample * fresnel * ENV_REFLECTION_STRENGTH;

  float rim_shadow = smoothstep(0.92, 1.0, sqrt(dist_sq));
  bg_color *= (1.0 - (rim_shadow * 0.25));

  vec3 final_color =
      (bg_color * (1.0 - vec3(fresnel))) +
      thin_film_color +
      env_reflection +
      highlights;

  float fade_out = 1.0 - pow(u_popProgress, 0.5);
  frag_color = vec4(mix(raw_background.rgb, final_color, fade_out), raw_background.a);
}
