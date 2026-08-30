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
const releaseLinks = document.querySelectorAll('.release-link');
const repository = releaseVersionLabels[0]?.dataset.repository;

if (repository) {
  fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
    headers: { Accept: 'application/vnd.github+json' },
    cache: 'no-store',
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
      const diskImage = Array.isArray(release.assets)
        ? release.assets.find((asset) => asset?.name === 'Web-Time.dmg')
        : undefined;
      if (typeof diskImage?.browser_download_url === 'string') {
        const downloadURL = new URL(diskImage.browser_download_url);
        if (downloadURL.protocol === 'https:' && downloadURL.hostname === 'github.com') {
          releaseLinks.forEach((link) => {
            link.href = downloadURL.href;
          });
        }
      }
    })
    .catch(() => {
      releaseVersionLabels.forEach((label) => {
        label.textContent = 'Version unavailable';
      });
    });
}
