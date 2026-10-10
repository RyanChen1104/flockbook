import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { features } from '$lib/content.js';

// Runs at prerender time. A slide needs a light still; the dark <source> is emitted only
// when <stem>-dark.png exists, so a dark-mode browser never requests a missing file.
const media = join(process.cwd(), 'static', 'media');

export function load() {
	const slides = features
		.filter((f) => f.image && existsSync(join(media, `${f.image}-light.png`)))
		.map((f) => ({ ...f, dark: existsSync(join(media, `${f.image}-dark.png`)) }));
	return { slides };
}
