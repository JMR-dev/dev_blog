import { test, expect } from '@playwright/test';
import { SITE_TITLE } from '../src/consts';

test.describe('Blog List Page', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/blog');
	});

	test('has correct page title', async ({ page }) => {
		await expect(page).toHaveTitle(`Articles · ${SITE_TITLE}`);
	});

	test('displays "Articles" heading', async ({ page }) => {
		await expect(page.getByRole('heading', { name: 'Articles', level: 1 })).toBeVisible();
	});

	test('shows all 6 posts (5 content + 1 fixture)', async ({ page }) => {
		const cards = page.locator('article.post-card');
		await expect(cards).toHaveCount(6);
	});

	test('posts are sorted newest first', async ({ page }) => {
		const cards = page.locator('article.post-card');
		await expect(cards.nth(0)).toContainText('Markdown Style Guide');
		await expect(cards.nth(1)).toContainText('Using MDX');
		await expect(cards.nth(2)).toContainText('Third post');
		await expect(cards.nth(3)).toContainText('Second post');
		await expect(cards.nth(4)).toContainText('First post');
		await expect(cards.nth(5)).toContainText('Test Fixture Post');
	});

	test('each post card has a clickable title link', async ({ page }) => {
		const cards = page.locator('article.post-card');
		const count = await cards.count();
		for (let i = 0; i < count; i++) {
			const link = cards.nth(i).getByRole('link');
			await expect(link).toBeVisible();
			const href = await link.getAttribute('href');
			expect(href).toMatch(/^\/blog\//);
		}
	});

	test('post cards display dates', async ({ page }) => {
		const times = page.locator('article.post-card time');
		await expect(times).toHaveCount(6);
	});

	test('post cards with tags show tag chips', async ({ page }) => {
		// All content posts except the test fixture have tags
		const tagRows = page.locator('article.post-card .tag-row');
		await expect(tagRows).toHaveCount(5);
	});

	test('post cards with readTime show read time', async ({ page }) => {
		// All content posts except the test fixture have readTime
		const dimItems = page.locator('article.post-card .meta-item.dim');
		await expect(dimItems).toHaveCount(5);
	});

	test('clicking a post card navigates to the post', async ({ page }) => {
		const firstLink = page.locator('article.post-card').first().getByRole('link');
		await firstLink.click();
		await expect(page).toHaveURL(/\/blog\//);
		await expect(page.locator('article')).toBeVisible();
	});
});
