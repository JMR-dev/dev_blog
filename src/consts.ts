// Place any global data in this file.
// You can import this data from anywhere in your site by using the `import` keyword.

export const SITE_TITLE = 'Jason Ross, SecDev.';
export const SITE_TAGLINE = 'Securing the web, one layer at a time.';
export const SITE_DESCRIPTION =
	'Application security, high-performance backend systems, and resilient interfaces — by a security-focused full-stack web developer.';

export const SOCIAL_LINKS = {
	github: 'https://github.com/JMR-dev',
	linkedin: 'https://linkedin.com/in/jasonmichaelross',
	mastodon: 'https://mastodon.social/@jason_ross_cyberdev',
};

export const NAV_LINKS = [
	{ name: 'Home', path: '/' },
	{ name: 'Articles', path: '/blog' },
	{ name: 'Projects', path: '/projects' },
	{ name: 'About', path: '/about' },
];

export const PROJECTS = [
	{
		name: 'AuthGuard',
		description:
			'A lightweight, memory-safe authentication middleware written in Rust for high-throughput microservices.',
		url: 'https://github.com',
	},
	{
		name: 'NetMonitor',
		description:
			'Real-time network traffic analysis and anomaly detection dashboard built with React, WebSockets, and Go.',
		url: 'https://github.com',
	},
];
