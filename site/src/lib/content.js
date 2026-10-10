// Links the owner fills in before launch. null renders a disabled placeholder.
export const links = {
	download: null, // e.g. GitHub Releases URL for Flockbook-<version>.dmg
	github: null // repository URL
};

// Each feature names a still pair in /media/: <image>-light.png and <image>-dark.png. Until they exist, `image` stays null
// and the page shows a labeled gray placeholder with the same aspect ratio.
export const features = [
	{
		id: 'read',
		title: 'Read what each agent did',
		body: 'Flockbook opens the agent’s own session log and shows the conversation as a document: your messages, its replies with Markdown, code and tables, and tool calls folded into short summaries.',
		image: 'conversation',
		alt: 'A conversation with an agent, shown as formatted text with folded tool calls.'
	},
	{
		id: 'needs-you',
		title: 'See which one needs you',
		body: 'Agents that wait for you go to the Needs you list, marked in orange. When a tab becomes blocked, macOS shows a notification.',
		image: 'needs-you',
		alt: 'The Needs you list with two agents waiting for an answer.'
	},
	{
		id: 'reply',
		title: 'Reply in one place',
		body: 'Type under the conversation and press Return to send. Shift-Return adds a line. Input methods and dictation work, and you can paste images or attach a file path.',
		image: null,
		alt: 'The reply field under a conversation, with a pasted image.'
	},
	{
		id: 'answer',
		title: 'Answer questions and approvals',
		body: 'When an agent asks a question with options, pick one from a card. When it asks for permission, choose Allow or Deny without opening the terminal.',
		image: 'question',
		alt: 'A question card with three options and a permission card with Allow and Deny.'
	},
	{
		id: 'overview',
		title: 'Every workspace at a glance',
		body: 'The sidebar lists your Herdr workspaces. Overview shows each tab with its state: working, waiting for you, or done. Search finds a tab by its name, its workspace or its agent.',
		image: 'overview',
		alt: 'The Overview screen with workspaces and the state of each tab.'
	},
	{
		id: 'terminal',
		title: 'The terminal is one shortcut away',
		body: 'Press Control-backtick (⌃`) to see the real terminal of a pane. Flockbook does not replace Herdr. It is a reading view on top of it.',
		image: 'terminal',
		alt: 'The terminal of an agent pane shown in a sheet over the conversation.'
	}
];

export const agents = ['Claude Code', 'Codex', 'Cursor', 'pi'];
