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
const releaseVersionLabels = document.querySelectorAll('[data-latest-release-version]');
const repository = releaseVersionLabels[0]?.dataset.repository;

if (repository && !repository.startsWith('__')) {
  fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
    headers: { Accept: 'application/vnd.github+json' },
  })
    .then((response) => {
      if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
      return response.json();
    })
    .then((release) => {
      if (typeof release.tag_name !== 'string' || !release.tag_name.trim()) return;
      const version = release.tag_name.trim().replace(/^v(?=\d)/i, '');
      releaseVersionLabels.forEach((label) => {
        label.textContent = `Version ${version}`;
      });
    })
    .catch(() => {
      // "Latest release" remains accurate if GitHub is unavailable.
    });
}
