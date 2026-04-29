import { describe, it, expect } from 'vitest';
import {
	SITE_TITLE,
	SITE_TAGLINE,
	SITE_DESCRIPTION,
	SOCIAL_LINKS,
	NAV_LINKS,
	PROJECTS,
} from '../../consts';

describe('SITE_TITLE', () => {
	it('is a non-empty string', () => {
		expect(SITE_TITLE).toBeTypeOf('string');
		expect(SITE_TITLE.length).toBeGreaterThan(0);
	});
});

describe('SITE_TAGLINE', () => {
	it('is a non-empty string', () => {
		expect(SITE_TAGLINE).toBeTypeOf('string');
		expect(SITE_TAGLINE.length).toBeGreaterThan(0);
	});
});

describe('SITE_DESCRIPTION', () => {
	it('is a non-empty string', () => {
		expect(SITE_DESCRIPTION).toBeTypeOf('string');
		expect(SITE_DESCRIPTION.length).toBeGreaterThan(0);
	});
});

describe('SOCIAL_LINKS', () => {
	it('has github, linkedin, and mastodon keys', () => {
		expect(SOCIAL_LINKS).toHaveProperty('github');
		expect(SOCIAL_LINKS).toHaveProperty('linkedin');
		expect(SOCIAL_LINKS).toHaveProperty('mastodon');
	});

	it('all values are absolute https URLs', () => {
		for (const url of Object.values(SOCIAL_LINKS)) {
			expect(url).toMatch(/^https:\/\//);
		}
	});

	it('github URL contains github.com', () => {
		expect(SOCIAL_LINKS.github).toContain('github.com');
	});

	it('linkedin URL contains linkedin.com', () => {
		expect(SOCIAL_LINKS.linkedin).toContain('linkedin.com');
	});

	it('mastodon URL contains mastodon.social', () => {
		expect(SOCIAL_LINKS.mastodon).toContain('mastodon.social');
	});
});

describe('NAV_LINKS', () => {
	it('is a non-empty array', () => {
		expect(Array.isArray(NAV_LINKS)).toBe(true);
		expect(NAV_LINKS.length).toBeGreaterThan(0);
	});

	it('contains Home, Articles, Projects, and About entries', () => {
		const names = NAV_LINKS.map((l) => l.name);
		expect(names).toContain('Home');
		expect(names).toContain('Articles');
		expect(names).toContain('Projects');
		expect(names).toContain('About');
	});

	it('all paths start with /', () => {
		for (const link of NAV_LINKS) {
			expect(link.path).toMatch(/^\//);
		}
	});

	it('paths are unique', () => {
		const paths = NAV_LINKS.map((l) => l.path);
		expect(new Set(paths).size).toBe(paths.length);
	});

	it('Home path is /', () => {
		expect(NAV_LINKS.find((l) => l.name === 'Home')?.path).toBe('/');
	});

	it('Articles path is /blog', () => {
		expect(NAV_LINKS.find((l) => l.name === 'Articles')?.path).toBe('/blog');
	});

	it('Projects path is /projects', () => {
		expect(NAV_LINKS.find((l) => l.name === 'Projects')?.path).toBe('/projects');
	});

	it('About path is /about', () => {
		expect(NAV_LINKS.find((l) => l.name === 'About')?.path).toBe('/about');
	});
});

describe('PROJECTS', () => {
	it('is a non-empty array', () => {
		expect(Array.isArray(PROJECTS)).toBe(true);
		expect(PROJECTS.length).toBeGreaterThan(0);
	});

	it('each project has non-empty name, description, and url', () => {
		for (const p of PROJECTS) {
			expect(p.name).toBeTypeOf('string');
			expect(p.name.length).toBeGreaterThan(0);
			expect(p.description).toBeTypeOf('string');
			expect(p.description.length).toBeGreaterThan(0);
			expect(p.url).toBeTypeOf('string');
			expect(p.url.length).toBeGreaterThan(0);
		}
	});

	it('project names are unique', () => {
		const names = PROJECTS.map((p) => p.name);
		expect(new Set(names).size).toBe(names.length);
	});

	it('all project URLs are absolute https URLs', () => {
		for (const p of PROJECTS) {
			expect(p.url).toMatch(/^https:\/\//);
		}
	});

	it('contains AuthGuard project', () => {
		expect(PROJECTS.find((p) => p.name === 'AuthGuard')).toBeDefined();
	});

	it('contains NetMonitor project', () => {
		expect(PROJECTS.find((p) => p.name === 'NetMonitor')).toBeDefined();
	});
});
