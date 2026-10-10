<script>
	import { base } from '$app/paths';
	import { links, features, agents } from '$lib/content.js';
</script>

<svelte:head>
	<title>Flockbook for Herdr</title>
	<meta
		name="description"
		content="A native macOS reading view for your Herdr agents. Read what each agent did, see which one needs you, and reply in one place."
	/>
</svelte:head>

<a class="skip" href="#main">Skip to content</a>

<header class="top">
	<div class="wrap top-row">
		<a class="brand" href="#top" aria-label="Flockbook, top of page">
			<picture>
				<source srcset="{base}/flockbook-dark.svg" media="(prefers-color-scheme: dark)" />
				<img src="{base}/flockbook-light.svg" alt="" width="28" height="28" />
			</picture>
			<span>Flockbook</span>
		</a>
		<nav aria-label="Sections">
			<a href="#features">Features</a>
			<a href="#requirements">Requirements</a>
			<a href="#install">Install</a>
		</nav>
	</div>
</header>

<main id="main">
	<section class="hero wrap" id="top">
		<picture>
			<source srcset="{base}/flockbook-dark.svg" media="(prefers-color-scheme: dark)" />
			<img class="hero-icon" src="{base}/flockbook-light.svg" alt="Flockbook app icon" width="160" height="160" />
		</picture>
		<h1>Flockbook for Herdr</h1>
		<p class="lede">
			A native macOS reading view for your Herdr agents. Read what each agent did, see which one
			needs you, and reply in one place.
		</p>
		<div class="actions">
			{#if links.download}
				<a class="button primary" href={links.download}>Download for macOS</a>
			{:else}
				<span class="button primary disabled" aria-disabled="true">Download for macOS</span>
			{/if}
			<a class="button" href="#install">Install guide</a>
		</div>
		<p class="fine">
			{#if !links.download}First release coming soon.{/if}
			Requires macOS 26 and Herdr. MIT license.
		</p>
	</section>

	<section class="intro wrap narrow" aria-label="About">
		<p>
			Your agents’ conversations are already in the terminal. Flockbook shows the same conversation
			in a layout that is easier to read.
		</p>
	</section>

	<section id="features" class="features wrap" aria-labelledby="features-title">
		<h2 id="features-title" class="visually-hidden">Features</h2>
		{#each features as f, i (f.id)}
			<article class="feature" class:flip={i % 2 === 1}>
				<div class="copy">
					<h3>{f.title}</h3>
					<p>{f.body}</p>
				</div>
				<figure class="shot">
					{#if f.image}
						<img src="{base}/media/{f.image}" alt={f.alt} loading="lazy" decoding="async" />
					{:else}
						<div class="placeholder" role="img" aria-label="Screenshot placeholder: {f.alt}">
							<span>Screenshot</span>
							<span class="ph-name">{f.title}</span>
						</div>
					{/if}
				</figure>
			</article>
		{/each}
	</section>

	<section id="requirements" class="panel wrap narrow" aria-labelledby="req-title">
		<h2 id="req-title">Requirements</h2>
		<dl class="facts">
			<div>
				<dt>macOS</dt>
				<dd>macOS 26 or later. Universal build for Apple silicon and Intel.</dd>
			</div>
			<div>
				<dt>Herdr</dt>
				<dd>
					<a href="https://herdr.dev">Herdr</a>, running. Flockbook talks to it through its local
					socket.
				</dd>
			</div>
			<div>
				<dt>Agents</dt>
				<dd>
					{agents.slice(0, -1).join(', ')} or {agents.at(-1)}, running in Herdr. Flockbook reads their
					local session logs to show the conversation.
				</dd>
			</div>
		</dl>
	</section>

	<section id="install" class="panel wrap narrow" aria-labelledby="install-title">
		<h2 id="install-title">Install</h2>
		<ol class="steps">
			<li>
				Download <code>Flockbook-&lt;version&gt;.dmg</code> from
				{#if links.github}<a href="{links.github}/releases">GitHub Releases</a>{:else}GitHub Releases{/if}.
				You can check it against <code>SHA256SUMS</code>.
			</li>
			<li>Open the disk image and drag Flockbook to Applications.</li>
			<li>Start Herdr, then open Flockbook.</li>
		</ol>
		<p class="note">
			Release notes say whether a build is signed and notarized. macOS blocks an unsigned build on
			first open. To run it anyway:
		</p>
		<pre><code>xattr -dr com.apple.quarantine /Applications/Flockbook.app</code></pre>
		<p class="note">Homebrew: not available yet.</p>
	</section>

	<section class="panel wrap narrow" aria-labelledby="privacy-title">
		<h2 id="privacy-title">Privacy</h2>
		<p>
			Flockbook runs on your Mac. It reads agent session logs on disk and talks to Herdr through its
			local socket. It sends nothing over the network and has no telemetry. A setting turns off all
			input, so the app only reads.
		</p>
	</section>
</main>

<footer class="foot">
	<div class="wrap foot-row">
		<p>
			Flockbook is unofficial. It is not affiliated with, endorsed by, or supported by Herdr, Inc.
		</p>
		<p class="foot-links">
			{#if links.github}
				<a href={links.github}>GitHub</a>
			{:else}
				<span aria-disabled="true">GitHub (link coming soon)</span>
			{/if}
			<span aria-hidden="true">·</span>
			<span>MIT License</span>
		</p>
	</div>
</footer>

<style>
	:global(:root) {
		--bg: #ffffff;
		--bg-2: #f5f5f7;
		--fg: #1d1d1f;
		--fg-2: #5e5e63;
		--line: #e3e3e6;
		--accent: #0066d6;
		--accent-fg: #ffffff;
		--accent-bg: #0066d6;
		--ph-a: #ececef;
		--ph-b: #e3e3e7;
		--radius: 14px;
		color-scheme: light dark;
	}
	@media (prefers-color-scheme: dark) {
		:global(:root) {
			--bg: #1e1e1f;
			--bg-2: #262628;
			--fg: #f5f5f7;
			--fg-2: #a8a8ad;
			--line: #3a3a3d;
			--accent: #0a84ff;
			--accent-fg: #ffffff;
			--accent-bg: #0071e3;
			--ph-a: #2c2c2e;
			--ph-b: #333336;
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
	}
	:global(body) {
		margin: 0;
		background: var(--bg);
		color: var(--fg);
		font:
			17px/1.55 -apple-system,
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
		outline-offset: 2px;
		border-radius: 6px;
	}

	.wrap {
		max-width: 1080px;
		margin: 0 auto;
		padding: 0 20px;
	}
	.narrow {
		max-width: 720px;
	}
	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
	}
	.skip {
		position: absolute;
		left: 12px;
		top: -48px;
		background: var(--bg);
		padding: 8px 12px;
		border-radius: 8px;
		z-index: 10;
	}
	.skip:focus {
		top: 12px;
	}

	.top {
		position: sticky;
		top: 0;
		z-index: 5;
		background: color-mix(in srgb, var(--bg) 82%, transparent);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
		backdrop-filter: saturate(180%) blur(20px);
		border-bottom: 1px solid var(--line);
	}
	.top-row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		height: 52px;
		gap: 16px;
	}
	.brand {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--fg);
		font-weight: 600;
		font-size: 15px;
	}
	.brand img {
		display: block;
	}
	nav {
		display: flex;
		gap: 20px;
		font-size: 14px;
	}
	nav a {
		color: var(--fg-2);
	}
	nav a:hover {
		color: var(--fg);
		text-decoration: none;
	}

	.hero {
		text-align: center;
		padding-top: 96px;
		padding-bottom: 48px;
	}
	.hero-icon {
		display: block;
		margin: 0 auto 24px;
		width: 160px;
		height: 160px;
	}
	h1 {
		font-size: clamp(36px, 6vw, 56px);
		line-height: 1.08;
		letter-spacing: -0.02em;
		font-weight: 700;
		margin: 0 0 16px;
	}
	.lede {
		font-size: clamp(19px, 2.4vw, 23px);
		color: var(--fg-2);
		max-width: 620px;
		margin: 0 auto 32px;
		line-height: 1.45;
	}
	.actions {
		display: flex;
		justify-content: center;
		flex-wrap: wrap;
		gap: 12px;
	}
	.button {
		display: inline-flex;
		align-items: center;
		min-height: 44px;
		padding: 0 22px;
		border-radius: 999px;
		font-size: 16px;
		font-weight: 500;
		border: 1px solid var(--line);
		color: var(--fg);
		background: var(--bg);
	}
	.button:hover {
		text-decoration: none;
		background: var(--bg-2);
	}
	.button.primary {
		background: var(--accent-bg);
		border-color: var(--accent-bg);
		color: var(--accent-fg);
	}
	.button.primary:hover {
		filter: brightness(1.08);
	}
	.button.disabled {
		cursor: default;
		opacity: 0.55;
		filter: none;
	}
	.fine {
		margin: 16px 0 0;
		font-size: 14px;
		color: var(--fg-2);
	}

	.intro {
		text-align: center;
		padding-bottom: 48px;
	}
	.intro p {
		font-size: 19px;
		color: var(--fg-2);
		margin: 0;
	}

	.features {
		display: grid;
		gap: 96px;
		padding-top: 48px;
		padding-bottom: 96px;
	}
	.feature {
		display: grid;
		grid-template-columns: minmax(0, 5fr) minmax(0, 7fr);
		align-items: center;
		gap: 56px;
	}
	.feature.flip {
		grid-template-columns: minmax(0, 7fr) minmax(0, 5fr);
	}
	.feature.flip .copy {
		order: 2;
	}
	h3 {
		font-size: 28px;
		line-height: 1.2;
		letter-spacing: -0.01em;
		margin: 0 0 12px;
	}
	.copy p {
		margin: 0;
		color: var(--fg-2);
	}
	.shot {
		margin: 0;
	}
	.shot img,
	.placeholder {
		display: block;
		width: 100%;
		aspect-ratio: 16 / 10;
		border-radius: var(--radius);
		border: 1px solid var(--line);
	}
	.shot img {
		height: auto;
		object-fit: cover;
	}
	.placeholder {
		background: repeating-linear-gradient(135deg, var(--ph-a) 0 14px, var(--ph-b) 14px 28px);
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 4px;
		color: var(--fg-2);
		font-size: 13px;
		text-transform: uppercase;
		letter-spacing: 0.08em;
	}
	.ph-name {
		text-transform: none;
		letter-spacing: 0;
		font-size: 15px;
		color: var(--fg);
	}

	.panel {
		padding-top: 56px;
		padding-bottom: 56px;
		border-top: 1px solid var(--line);
	}
	h2 {
		font-size: 30px;
		letter-spacing: -0.01em;
		margin: 0 0 24px;
	}
	.facts {
		margin: 0;
		display: grid;
		gap: 16px;
	}
	.facts div {
		display: grid;
		grid-template-columns: 120px minmax(0, 1fr);
		gap: 16px;
	}
	dt {
		font-weight: 600;
	}
	dd {
		margin: 0;
		color: var(--fg-2);
	}
	.steps {
		margin: 0 0 20px;
		padding-left: 1.4em;
		display: grid;
		gap: 8px;
	}
	.note {
		color: var(--fg-2);
		margin: 0 0 12px;
	}
	code {
		font:
			0.9em ui-monospace,
			'SF Mono',
			Menlo,
			monospace;
	}
	pre {
		margin: 0 0 20px;
		padding: 14px 16px;
		background: var(--bg-2);
		border: 1px solid var(--line);
		border-radius: 10px;
		overflow-x: auto;
		font-size: 15px;
	}
	.panel p:last-child {
		margin-bottom: 0;
	}

	.foot {
		border-top: 1px solid var(--line);
		background: var(--bg-2);
		font-size: 14px;
		color: var(--fg-2);
	}
	.foot-row {
		padding-top: 28px;
		padding-bottom: 36px;
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		gap: 12px 32px;
	}
	.foot p {
		margin: 0;
	}
	.foot-links {
		display: flex;
		gap: 8px;
	}

	@media (max-width: 760px) {
		.hero {
			padding-top: 56px;
		}
		.hero-icon {
			width: 120px;
			height: 120px;
		}
		.features {
			gap: 64px;
		}
		.feature,
		.feature.flip {
			grid-template-columns: minmax(0, 1fr);
			gap: 20px;
		}
		.feature.flip .copy {
			order: 0;
		}
		h3 {
			font-size: 24px;
		}
		.facts div {
			grid-template-columns: minmax(0, 1fr);
			gap: 2px;
		}
	}
	@media (max-width: 420px) {
		nav {
			gap: 14px;
		}
		nav a:first-child {
			display: none;
		}
	}
</style>
