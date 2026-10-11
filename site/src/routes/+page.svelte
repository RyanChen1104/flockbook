<script>
	import { base } from '$app/paths';
	import { links, agents } from '$lib/content.js';

	let { data } = $props();
	const slides = data.slides;
</script>

<svelte:head>
	<title>Flockbook for Herdr</title>
	<meta
		name="description"
		content="A native macOS reading view for your Herdr agents. Read what each agent did, see which one needs you, and reply in one place."
	/>
	<script src="{base}/carousel.js" defer></script>
	<script src="{base}/flock.js" defer></script>
</svelte:head>

<a class="skip" href="#features">Skip to features</a>

<main>
	<section class="hero">
		<picture>
			<source srcset="{base}/flockbook-dark.svg" media="(prefers-color-scheme: dark)" />
			<img class="icon" src="{base}/flockbook-light.svg" alt="Flockbook app icon" width="144" height="144" />
		</picture>
		<h1>Flockbook</h1>
		<p class="pitch">A native macOS reading view for your Herdr agents.</p>
		<div class="actions">
			{#if links.download}
				<a class="download" href={links.download}>Download</a>
			{:else}
				<span class="download disabled" aria-disabled="true">Download <span class="soon">soon</span></span>
			{/if}
			{#if links.github}
				<a class="github" href={links.github}>GitHub</a>
			{/if}
		</div>
		<p class="req">macOS 26 · Herdr</p>
	</section>

	<section id="features" class="carousel" aria-roledescription="carousel" aria-label="Features">
		<div class="track" tabindex="0" aria-label="Features. Scroll sideways or use the links below.">
			{#each slides as f, i (f.id)}
				<figure
					class="slide"
					id="feature-{f.id}"
					role="group"
					aria-roledescription="slide"
					aria-label="{i + 1} of {slides.length}: {f.title}"
				>
					<div class="shot">
						<picture>
							{#if f.dark}
									<source srcset="{base}/media/{f.image}-dark.png" media="(prefers-color-scheme: dark)" />
								{/if}
								<img
									src="{base}/media/{f.image}-light.png"
									alt={f.alt}
									width="2560"
									height="1704"
									loading={i === 0 ? 'eager' : 'lazy'}
									decoding="async"
								/>
							</picture>
					</div>
					<figcaption>
						<p class="count" aria-hidden="true">{i + 1} / {slides.length}</p>
						<h2>{f.title}</h2>
						<p>{f.body}</p>
					</figcaption>
				</figure>
			{/each}
		</div>
		<nav class="dots" aria-label="Choose a feature">
			{#each slides as f, i (f.id)}
				<a href="#feature-{f.id}" aria-label="{i + 1}. {f.title}"><span></span></a>
			{/each}
		</nav>
	</section>
</main>

<footer class="foot">
	<dl class="facts">
		<div>
			<dt>Requires</dt>
			<dd>
				macOS 26 or later (Apple silicon and Intel) and a running <a href="https://herdr.dev">Herdr</a>
				with {agents.slice(0, -1).join(', ')} or {agents.at(-1)} agents.
			</dd>
		</div>
		<div>
			<dt>Install</dt>
			<dd>
				Download the <code>.dmg</code> from
				{#if links.github}<a href="{links.github}/releases">GitHub Releases</a>{:else}GitHub Releases{/if}
				and drag Flockbook to Applications. Signed and notarized by Apple. Check the download against
				<code>SHA256SUMS</code>.
				<small class="unsigned">
					Only if a build's release notes mark it unsigned:
					<code>xattr -dr com.apple.quarantine /Applications/Flockbook.app</code>
				</small>
			</dd>
		</div>
		<div>
			<dt>Privacy</dt>
			<dd>
				Runs locally. Reads agent session logs on your Mac and talks to Herdr through its local socket.
				Sends nothing over the network. No telemetry.
			</dd>
		</div>
	</dl>
	<p class="legal">
		{#if links.github}<a href={links.github}>GitHub</a>{' · '}{/if}MIT License · Unofficial. Not affiliated
		with, endorsed by, or supported by Herdr, Inc.
	</p>
	<canvas class="flock" aria-hidden="true"></canvas>
</footer>

<style>
	:global(:root) {
		--bg: #ffffff;
		--fg: #1d1d1f;
		--fg-2: #6e6e73;
		--line: #e5e5e8;
		--soft: #f5f5f7;
		--accent: #0066d6;
		--dot: #c7c7cc;
		color-scheme: light dark;
	}
	@media (prefers-color-scheme: dark) {
		:global(:root) {
			--bg: #161617;
			--fg: #f5f5f7;
			--fg-2: #a1a1a6;
			--line: #2f2f32;
			--soft: #222224;
			--accent: #3b9bff;
			--dot: #48484c;
		}
	}
	:global(*, *::before, *::after) {
		box-sizing: border-box;
	}
	:global(html) {
		scroll-behavior: smooth;
		-webkit-text-size-adjust: 100%;
	}
	@media (prefers-reduced-motion: reduce) {
		:global(html) {
			scroll-behavior: auto;
		}
		.track {
			scroll-behavior: auto !important;
		}
	}
	:global(body) {
		margin: 0;
		background: var(--bg);
		color: var(--fg);
		font:
			17px/1.5 -apple-system,
			BlinkMacSystemFont,
			'SF Pro Text',
			'Helvetica Neue',
			Helvetica,
			Arial,
			sans-serif;
		-webkit-font-smoothing: antialiased;
		overflow-x: hidden;
	}
	:global(a) {
		color: var(--accent);
		text-decoration: none;
	}
	:global(a:hover) {
		text-decoration: underline;
	}
	:global(:focus-visible) {
		outline: 3px solid var(--accent);
		outline-offset: 3px;
		border-radius: 8px;
	}
	.skip {
		position: absolute;
		left: 12px;
		top: -48px;
		background: var(--bg);
		padding: 8px 12px;
	}
	.skip:focus {
		top: 12px;
	}

	.hero {
		min-height: 88vh;
		min-height: 88svh;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		text-align: center;
		padding: 64px 20px;
	}
	.icon {
		display: block;
		width: 144px;
		height: 144px;
		margin-bottom: 28px;
	}
	h1 {
		font-size: clamp(44px, 8vw, 72px);
		line-height: 1;
		letter-spacing: -0.03em;
		font-weight: 700;
		margin: 0 0 16px;
	}
	.pitch {
		font-size: clamp(19px, 2.6vw, 24px);
		color: var(--fg-2);
		margin: 0 0 40px;
		max-width: 30ch;
	}
	.download {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		min-height: 48px;
		padding: 0 28px;
		border-radius: 999px;
		background: var(--fg);
		color: var(--bg);
		font-size: 17px;
		font-weight: 600;
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 12px;
	}
	.github {
		display: inline-flex;
		align-items: center;
		min-height: 48px;
		padding: 0 24px;
		border-radius: 999px;
		border: 1px solid var(--line);
		color: var(--fg);
		font-size: 17px;
		font-weight: 500;
	}
	.github:hover {
		text-decoration: none;
		background: var(--soft);
	}
	.download:hover {
		text-decoration: none;
		opacity: 0.88;
	}
	.download.disabled {
		background: var(--soft);
		color: var(--fg-2);
		cursor: default;
	}
	.soon {
		font-weight: 400;
		font-size: 14px;
	}
	.req {
		margin: 16px 0 0;
		font-size: 14px;
		color: var(--fg-2);
	}

	.carousel {
		max-width: 1120px;
		margin: 0 auto;
		padding: 0 20px 96px;
	}
	.track {
		display: grid;
		grid-auto-flow: column;
		grid-auto-columns: 100%;
		overflow-x: auto;
		scroll-snap-type: x mandatory;
		scroll-behavior: smooth;
		overscroll-behavior-x: contain;
		scrollbar-width: none;
	}
	.track::-webkit-scrollbar {
		display: none;
	}
	.slide {
		margin: 0;
		scroll-snap-align: center;
		scroll-snap-stop: always;
		scroll-margin-top: 24px;
		/* Room for the drop shadow and the focus ring inside the scroller's clip. */
		padding: 8px 24px 8px;
	}
	/* Stills are the whole window (1.5:1, transparent rounded corners): never crop them. */
	.shot img {
		display: block;
		width: 100%;
		height: auto;
		filter: drop-shadow(0 8px 24px rgb(0 0 0 / 0.12));
	}
	@media (prefers-color-scheme: dark) {
		.shot img {
			filter: drop-shadow(0 8px 24px rgb(0 0 0 / 0.5));
		}
	}
	figcaption {
		text-align: center;
		max-width: 56ch;
		margin: 28px auto 0;
	}
	h2 {
		font-size: 22px;
		letter-spacing: -0.01em;
		margin: 0 0 6px;
	}
	figcaption p {
		margin: 0;
		color: var(--fg-2);
	}
	figcaption .count {
		font-size: 13px;
		font-variant-numeric: tabular-nums;
		margin-bottom: 8px;
	}
	.dots {
		display: flex;
		justify-content: center;
		gap: 4px;
		margin-top: 24px;
	}
	.dots a {
		display: grid;
		place-items: center;
		width: 28px;
		height: 28px;
		border-radius: 50%;
	}
	.dots span {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--dot);
	}
	.dots a:hover span {
		background: var(--fg-2);
	}
	/* Set by carousel.js, so Svelte must not prune it as unused. */
	.dots :global(a[aria-current] span) {
		background: var(--fg);
	}

	.foot {
		border-top: 1px solid var(--line);
		max-width: 1120px;
		margin: 0 auto;
		padding: 40px 20px 48px;
		font-size: 14px;
		color: var(--fg-2);
	}
	.facts {
		margin: 0 0 32px;
		display: grid;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		gap: 32px;
	}
	dt {
		color: var(--fg);
		font-weight: 600;
		margin-bottom: 4px;
	}
	dd {
		margin: 0;
	}
	code {
		font:
			0.95em ui-monospace,
			'SF Mono',
			Menlo,
			monospace;
		overflow-wrap: anywhere;
	}
	.unsigned {
		display: block;
		margin-top: 8px;
		font-size: 12px;
	}
	.legal {
		margin: 0;
	}
	/* Fixed height: the canvas never shifts layout. */
	.flock {
		display: block;
		width: 100%;
		height: 160px;
		margin-top: 32px;
	}

	@media (max-width: 760px) {
		.hero {
			min-height: auto;
			padding: 80px 20px 64px;
		}
		.icon {
			width: 112px;
			height: 112px;
		}
		.carousel {
			padding: 0 0 64px;
		}
		.slide {
			padding: 4px 20px 8px;
		}
		.facts {
			grid-template-columns: minmax(0, 1fr);
			gap: 20px;
		}
	}
</style>
