(() => {
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  const showcase = document.querySelector(".showcase");
  if (!showcase) return;

  const track = showcase.querySelector(".showcase-track");
  const slides = [...showcase.querySelectorAll(".showcase-slide")];
  const tabs = showcase.querySelector(".showcase-tabs");
  const previous = showcase.querySelector(".showcase-arrow.previous");
  const next = showcase.querySelector(".showcase-arrow.next");
  let active = 0;
  let scrollFrame = 0;
  let autoTimer = 0;
  let hoverPaused = false;
  let focusPaused = false;

  function scheduleAutoAdvance() {
    window.clearTimeout(autoTimer);
    if (hoverPaused || focusPaused || document.hidden || reducedMotion.matches)
      return;
    autoTimer = window.setTimeout(() => {
      show(active + 1);
      scheduleAutoAdvance();
    }, 5200);
  }

  const buttons = slides.map((slide, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.role = "tab";
    button.textContent = slide.dataset.label;
    button.setAttribute("aria-label", `Show ${slide.dataset.label}`);
    button.addEventListener("click", () => {
      show(index);
      scheduleAutoAdvance();
    });
    tabs.appendChild(button);
    return button;
  });

  function update(index) {
    active = index;
    buttons.forEach((button, buttonIndex) => {
      const selected = buttonIndex === active;
      button.setAttribute("aria-selected", String(selected));
      button.tabIndex = selected ? 0 : -1;
    });
  }

  function show(index, behavior = "smooth") {
    const target = (index + slides.length) % slides.length;
    track.scrollTo({ left: slides[target].offsetLeft, behavior });
    update(target);
  }

  previous.addEventListener("click", () => {
    show(active - 1);
    scheduleAutoAdvance();
  });
  next.addEventListener("click", () => {
    show(active + 1);
    scheduleAutoAdvance();
  });

  track.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    show(active + (event.key === "ArrowRight" ? 1 : -1));
    scheduleAutoAdvance();
  });

  showcase.addEventListener("pointerenter", () => {
    hoverPaused = true;
    window.clearTimeout(autoTimer);
  });
  showcase.addEventListener("pointerleave", () => {
    hoverPaused = false;
    scheduleAutoAdvance();
  });
  showcase.addEventListener("focusin", () => {
    focusPaused = true;
    window.clearTimeout(autoTimer);
  });
  showcase.addEventListener("focusout", (event) => {
    if (showcase.contains(event.relatedTarget)) return;
    focusPaused = false;
    scheduleAutoAdvance();
  });
  document.addEventListener("visibilitychange", scheduleAutoAdvance);
  reducedMotion.addEventListener("change", scheduleAutoAdvance);

  track.addEventListener(
    "scroll",
    () => {
      cancelAnimationFrame(scrollFrame);
      scrollFrame = requestAnimationFrame(() => {
        let closest = 0;
        let distance = Infinity;
        slides.forEach((slide, index) => {
          const current = Math.abs(slide.offsetLeft - track.scrollLeft);
          if (current < distance) {
            closest = index;
            distance = current;
          }
        });
        update(closest);
        scheduleAutoAdvance();
      });
    },
    { passive: true },
  );

  update(0);
  scheduleAutoAdvance();
})();
