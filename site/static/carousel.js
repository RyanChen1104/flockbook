// Marks the dot of the visible slide (aria-current) and scrolls only the track on dot click.
// Without this script the dots are plain anchor links.
(() => {
	const track = document.querySelector('.track');
	const dots = [...document.querySelectorAll('.dots a')];
	if (!track || !dots.length) return;
	const still = matchMedia('(prefers-reduced-motion: reduce)');
	const mark = (i) => dots.forEach((d, j) => (j === i ? d.setAttribute('aria-current', 'true') : d.removeAttribute('aria-current')));
	const visible = () => Math.round(track.scrollLeft / track.clientWidth);
	let frame = 0;
	track.addEventListener('scroll', () => {
		cancelAnimationFrame(frame);
		frame = requestAnimationFrame(() => mark(visible()));
	}, { passive: true });
	dots.forEach((d, i) =>
		d.addEventListener('click', (e) => {
			e.preventDefault();
			track.scrollTo({ left: i * track.clientWidth, behavior: still.matches ? 'auto' : 'smooth' });
			mark(i);
		})
	);
	mark(visible());
})();
