// Links the owner fills in before launch. null renders a disabled placeholder.
export const links = {
	download: null, // e.g. GitHub Releases URL for Flockbook-<version>.dmg
	github: null // repository URL
};

// Each feature names a still stem in /media/: <image>-light.png and, optionally, <image>-dark.png.
// A feature with no image (or no light still on disk) is left out of the carousel.
// `body` is one sentence: it is the slide caption.
export const features = [
	{
		id: 'read',
		title: 'Read what each agent did',
		body: 'The agent’s own session log, shown as a document with Markdown, code, tables and tool calls folded into short summaries.',
		image: 'conversation',
		alt: 'A conversation with an agent, shown as formatted text with folded tool calls.'
	},
	{
		id: 'needs-you',
		title: 'See which one needs you',
		body: 'Agents that wait for you go to the Needs you list, and macOS notifies you when a tab becomes blocked.',
		image: 'needs-you',
		alt: 'The Needs you list with two agents waiting for an answer.'
	},
	{
		id: 'reply',
		title: 'Reply in one place',
		body: 'Type under the conversation and press Return to send, with input methods, dictation and pasted images.',
		image: null,
		alt: 'The reply field under a conversation, with a pasted image.'
	},
	{
		id: 'answer',
		title: 'Answer questions and approvals',
		body: 'Pick an option or choose Allow or Deny from a card, without opening the terminal.',
		image: 'question',
		alt: 'A question card with three options and a permission card with Allow and Deny.'
	},
	{
		id: 'overview',
		title: 'Every workspace at a glance',
		body: 'Overview shows every tab of every workspace with its state: working, waiting for you, or done.',
		image: 'overview',
		alt: 'The Overview screen with workspaces and the state of each tab.'
	},
	{
		id: 'terminal',
		title: 'The terminal is one shortcut away',
		body: 'Press Control-backtick (⌃`) to see the real terminal of a pane.',
		image: 'terminal',
		alt: 'The terminal of an agent pane shown in a sheet over the conversation.'
	}
];

export const agents = ['Claude Code', 'Codex', 'Cursor', 'pi'];
