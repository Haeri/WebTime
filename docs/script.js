const revealItems = document.querySelectorAll('.reveal');
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

if (reduceMotion || !('IntersectionObserver' in window)) {
  revealItems.forEach((item) => item.classList.add('is-visible'));
} else {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.15 });
  revealItems.forEach((item) => observer.observe(item));
}

if (!reduceMotion) {
  const ring = document.querySelector('.ambient-ring');
  let scheduled = false;
  window.addEventListener('scroll', () => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      const turn = Math.min(window.scrollY * 0.025, 18);
      ring.style.transform = `rotate(${turn - 12}deg)`;
      scheduled = false;
    });
  }, { passive: true });
}
