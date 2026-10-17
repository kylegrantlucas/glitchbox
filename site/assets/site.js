// Clips ship with native controls and no autoplay, so they work without this
// script. With it, clips loop silently while on screen, unless the visitor
// prefers reduced motion or presses "Pause clips"; paused clips get their
// controls back so each can still be played by hand.
(() => {
  const clips = [...document.querySelectorAll("video.clip")];
  const toggle = document.querySelector(".motion-toggle");
  if (!clips.length || !toggle) return;

  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const visible = new Set();
  let paused = false;

  const update = (v) => {
    if (paused) return;
    if (!visible.has(v)) { v.pause(); return; }
    v.muted = true;
    if (v.preload === "none") v.preload = "auto";
    v.play().catch(() => { v.controls = true; });
  };

  const setPaused = (p) => {
    paused = p;
    toggle.setAttribute("aria-pressed", String(p));
    for (const v of clips) {
      v.controls = p;
      if (p) v.pause(); else update(v);
    }
  };

  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) visible.add(e.target); else visible.delete(e.target);
      update(e.target);
    }
  }, { rootMargin: "200px 0px" });

  toggle.hidden = false;
  toggle.addEventListener("click", () => setPaused(!paused));
  reduce.addEventListener("change", () => setPaused(reduce.matches));
  setPaused(reduce.matches);
  clips.forEach((v) => io.observe(v));
})();
