import { test, expect } from '@playwright/test';
import { SITE_TITLE, SITE_DESCRIPTION } from '../src/consts';

test.describe('RSS Feed', () => {
	test('responds with 200', async ({ request }) => {
		const response = await request.get('/rss.xml');
		expect(response.status()).toBe(200);
	});

	test('returns XML content type', async ({ request }) => {
		const response = await request.get('/rss.xml');
		const contentType = response.headers()['content-type'];
		expect(contentType).toMatch(/xml/);
	});

	test('contains RSS root element', async ({ request }) => {
		const response = await request.get('/rss.xml');
		const body = await response.text();
		expect(body).toMatch(/<rss/);
	});

	test('contains channel title matching SITE_TITLE', async ({ request }) => {
		const response = await request.get('/rss.xml');
		const body = await response.text();
		expect(body).toContain(`<title>${SITE_TITLE}</title>`);
	});

	test('contains channel description matching SITE_DESCRIPTION', async ({ request }) => {
		const response = await request.get('/rss.xml');
		const body = await response.text();
		expect(body).toContain(SITE_DESCRIPTION);
	});

	test('contains all 6 items (5 content + 1 fixture)', async ({ request }) => {
		const response = await request.get('/rss.xml');
		const body = await response.text();
		const itemMatches = body.match(/<item>/g);
		expect(itemMatches).not.toBeNull();
		expect(itemMatches!.length).toBe(6);
	});

	test('items contain /blog/ links', async ({ request }) => {
		const response = await request.get('/rss.xml');
		const body = await response.text();
		// Each item should have a link to /blog/
		expect(body).toContain('/blog/first-post/');
		expect(body).toContain('/blog/second-post/');
		expect(body).toContain('/blog/third-post/');
		expect(body).toContain('/blog/markdown-style-guide/');
		expect(body).toContain('/blog/using-mdx/');
		expect(body).toContain('/blog/test-fixture/');
	});
});
