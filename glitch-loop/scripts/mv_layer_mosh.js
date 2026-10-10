// Timed mosh for the "layered composite" combine pipeline.
// Total input is 112.111s (loop_mosh length). Religions was blended in over
// the last 67s starting at 45.111s. Mosh begins the moment religions enters,
// ramps quickly, then amplifies as the two signals collapse into each other.

const total_frames = 3363;
const fps = 30;
const mosh_start = Math.round(60 * fps);     // = 1800 (mosh creeps in during peak-Huston)
const ramp_frames = 5 * fps;                 // 5s ramp
const amplify_start = mosh_start + ramp_frames;
const tail_length = 10;
const min_divisor = 4;                       // gentler amplification so religions survives

let prev_fwd_mvs = [];
let total_sum;
let frame_idx = 0;

export function setup(args) {
  args.features = ["mv"];
}

export function glitch_frame(frame) {
  const fwd_mvs = frame.mv?.forward;
  if (!fwd_mvs) { frame_idx++; return; }
  frame.mv.overflow = "truncate";

  const dc = fwd_mvs.dup();
  prev_fwd_mvs.push(dc);

  if (!total_sum) total_sum = new MV2DArray(fwd_mvs.width, fwd_mvs.height);
  if (prev_fwd_mvs.length > tail_length) {
    total_sum.sub(prev_fwd_mvs[0]);
    prev_fwd_mvs = prev_fwd_mvs.slice(1);
  }
  total_sum.add(dc);

  const local_idx = frame_idx;
  frame_idx++;

  if (prev_fwd_mvs.length < tail_length) return;
  if (local_idx < mosh_start) return; // pre-religions: source MVs untouched

  // Ramp: rare application → every-frame, over [mosh_start, amplify_start)
  let apply_every;
  if (local_idx >= amplify_start) {
    apply_every = 1;
  } else {
    const t = (local_idx - mosh_start) / ramp_frames;
    apply_every = Math.max(1, Math.round(30 - 29 * t));
  }
  if (local_idx % apply_every !== 0) return;

  // Divisor: tail_length → min_divisor across amplify phase (smaller = amplified)
  let divisor = tail_length;
  if (local_idx > amplify_start) {
    const back_frac = Math.min(1, (local_idx - amplify_start) / (total_frames - amplify_start));
    divisor = Math.max(min_divisor, Math.round(tail_length - (tail_length - min_divisor) * back_frac));
  }

  fwd_mvs.assign(total_sum);
  fwd_mvs.div(MV(divisor, divisor));
}
