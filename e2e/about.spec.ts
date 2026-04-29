import { test, expect } from '@playwright/test';
import { SITE_TITLE, SOCIAL_LINKS } from '../src/consts';

test.describe('About Page', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/about');
	});

	test('has correct page title', async ({ page }) => {
		await expect(page).toHaveTitle(`About · ${SITE_TITLE}`);
	});

	test('displays "The Manifesto" heading', async ({ page }) => {
		await expect(page.getByRole('heading', { name: 'The Manifesto', level: 1 })).toBeVisible();
	});

	test('displays the lede paragraph', async ({ page }) => {
		await expect(page.locator('.lede')).toBeVisible();
	});

	test('displays "What you\'ll find here" section', async ({ page }) => {
		await expect(page.getByRole('heading', { name: /what you.ll find here/i })).toBeVisible();
	});

	test('displays "Get in touch" section', async ({ page }) => {
		await expect(page.getByRole('heading', { name: /get in touch/i })).toBeVisible();
	});

	test('LinkedIn social link is present with correct href', async ({ page }) => {
		const link = page.getByRole('link', { name: 'LinkedIn' }).last();
		await expect(link).toHaveAttribute('href', SOCIAL_LINKS.linkedin);
		await expect(link).toHaveAttribute('target', '_blank');
		await expect(link).toHaveAttribute('rel', 'noopener noreferrer');
	});

	test('Mastodon social link is present with correct href', async ({ page }) => {
		const link = page.getByRole('link', { name: 'Mastodon' }).last();
		await expect(link).toHaveAttribute('href', SOCIAL_LINKS.mastodon);
		await expect(link).toHaveAttribute('target', '_blank');
		await expect(link).toHaveAttribute('rel', 'noopener noreferrer');
	});

	test('GitHub social link is present with correct href', async ({ page }) => {
		const link = page.getByRole('link', { name: 'GitHub' }).last();
		await expect(link).toHaveAttribute('href', SOCIAL_LINKS.github);
		await expect(link).toHaveAttribute('target', '_blank');
		await expect(link).toHaveAttribute('rel', 'noopener noreferrer');
	});

	test('prose section contains "defense in depth"', async ({ page }) => {
		await expect(page.locator('.prose')).toContainText('defense in depth');
	});
});
