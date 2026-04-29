import { test, expect } from '@playwright/test';
import { SITE_TITLE, SITE_DESCRIPTION, PROJECTS } from '../src/consts';

test.describe('Homepage', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/');
	});

	test('has correct page title', async ({ page }) => {
		await expect(page).toHaveTitle(SITE_TITLE);
	});

	test('has correct og:title meta tag', async ({ page }) => {
		const ogTitle = page.locator('meta[property="og:title"]');
		await expect(ogTitle).toHaveAttribute('content', SITE_TITLE);
	});

	test('has og:description meta tag', async ({ page }) => {
		const ogDesc = page.locator('meta[property="og:description"]');
		await expect(ogDesc).toHaveAttribute('content', SITE_DESCRIPTION);
	});

	test('has canonical link', async ({ page }) => {
		const canonical = page.locator('link[rel="canonical"]');
		await expect(canonical).toHaveAttribute('href', /^https?:\/\//);
	});

	test('has RSS alternate link', async ({ page }) => {
		const rssLink = page.locator('link[rel="alternate"][type="application/rss+xml"]');
		await expect(rssLink).toHaveAttribute('href', /rss\.xml/);
	});

	test('displays "System Online" badge', async ({ page }) => {
		await expect(page.getByText('System Online')).toBeVisible();
	});

	test('displays hero heading', async ({ page }) => {
		await expect(page.locator('h1')).toContainText('Securing the web');
	});

	test('displays hero accent text', async ({ page }) => {
		await expect(page.locator('.accent')).toContainText('one layer at a time');
	});

	test('"Read my manifesto" button links to /about', async ({ page }) => {
		const btn = page.getByRole('link', { name: /read my manifesto/i });
		await expect(btn).toBeVisible();
		await expect(btn).toHaveAttribute('href', '/about');
	});

	test('displays "Latest Articles" section', async ({ page }) => {
		await expect(page.getByRole('heading', { name: 'Latest Articles' })).toBeVisible();
	});

	test('shows exactly 3 recent posts', async ({ page }) => {
		const postSection = page.locator('section.latest');
		const cards = postSection.locator('article.post-card');
		await expect(cards).toHaveCount(3);
	});

	test('latest posts are sorted newest first', async ({ page }) => {
		const postSection = page.locator('section.latest');
		const cards = postSection.locator('article.post-card');
		// Most recent post at index 0 should be "Markdown Style Guide" (Jun 19 2024)
		await expect(cards.nth(0)).toContainText('Markdown Style Guide');
		// Second should be "Using MDX" (Jun 01 2024)
		await expect(cards.nth(1)).toContainText('Using MDX');
		// Third should be "Third post" (Jul 22 2022)
		await expect(cards.nth(2)).toContainText('Third post');
	});

	test('"View all" link goes to /blog', async ({ page }) => {
		const viewAll = page.getByRole('link', { name: /view all/i });
		await expect(viewAll).toBeVisible();
		await expect(viewAll).toHaveAttribute('href', '/blog');
	});

	test('displays "Open Source" section', async ({ page }) => {
		await expect(page.getByRole('heading', { name: 'Open Source' })).toBeVisible();
	});

	test('shows all projects', async ({ page }) => {
		for (const project of PROJECTS) {
			await expect(page.getByRole('heading', { name: project.name })).toBeVisible();
		}
	});

	test('project cards link to external URLs', async ({ page }) => {
		const projectSection = page.locator('section.projects');
		const projectLinks = projectSection.locator('a.project-card');
		for (let i = 0; i < PROJECTS.length; i++) {
			await expect(projectLinks.nth(i)).toHaveAttribute('target', '_blank');
			await expect(projectLinks.nth(i)).toHaveAttribute('rel', 'noopener noreferrer');
		}
	});

	test('footer shows current year', async ({ page }) => {
		const year = new Date().getFullYear().toString();
		await expect(page.locator('footer')).toContainText(year);
	});

	test('footer contains site title', async ({ page }) => {
		await expect(page.locator('footer')).toContainText(SITE_TITLE);
	});
});
