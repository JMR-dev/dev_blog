import { test, expect } from '@playwright/test';
import { NAV_LINKS, SOCIAL_LINKS, SITE_TITLE } from '../src/consts';

test.describe('Header and Navigation', () => {
	test('all nav links are present on every page', async ({ page }) => {
		for (const routeLink of NAV_LINKS) {
			await page.goto(routeLink.path);
			for (const navLink of NAV_LINKS) {
				const link = page.locator('nav.main-nav').getByRole('link', { name: navLink.name });
				await expect(link).toBeVisible();
				await expect(link).toHaveAttribute('href', navLink.path);
			}
		}
	});

	test('Home nav link is active on /', async ({ page }) => {
		await page.goto('/');
		const homeLink = page.locator('nav.main-nav').getByRole('link', { name: 'Home' });
		await expect(homeLink).toHaveClass(/active/);
	});

	test('Articles nav link is active on /blog', async ({ page }) => {
		await page.goto('/blog');
		const articlesLink = page.locator('nav.main-nav').getByRole('link', { name: 'Articles' });
		await expect(articlesLink).toHaveClass(/active/);
	});

	test('Articles nav link is active on an individual blog post', async ({ page }) => {
		await page.goto('/blog/first-post/');
		const articlesLink = page.locator('nav.main-nav').getByRole('link', { name: 'Articles' });
		await expect(articlesLink).toHaveClass(/active/);
	});

	test('Projects nav link is active on /projects', async ({ page }) => {
		await page.goto('/projects');
		const projectsLink = page.locator('nav.main-nav').getByRole('link', { name: 'Projects' });
		await expect(projectsLink).toHaveClass(/active/);
	});

	test('About nav link is active on /about', async ({ page }) => {
		await page.goto('/about');
		const aboutLink = page.locator('nav.main-nav').getByRole('link', { name: 'About' });
		await expect(aboutLink).toHaveClass(/active/);
	});

	test('brand logo links to /', async ({ page }) => {
		await page.goto('/about');
		const brand = page.locator('a.brand');
		await expect(brand).toHaveAttribute('href', '/');
		await expect(brand).toHaveAttribute('aria-label', SITE_TITLE);
	});

	test('social bar shows GitHub, LinkedIn, Mastodon links', async ({ page }) => {
		await page.goto('/');
		const socialBar = page.locator('.social-bar');

		const github = socialBar.getByRole('link', { name: 'GitHub' });
		await expect(github).toHaveAttribute('href', SOCIAL_LINKS.github);
		await expect(github).toHaveAttribute('target', '_blank');
		await expect(github).toHaveAttribute('rel', 'noopener noreferrer');

		const linkedin = socialBar.getByRole('link', { name: 'LinkedIn' });
		await expect(linkedin).toHaveAttribute('href', SOCIAL_LINKS.linkedin);

		const mastodon = socialBar.getByRole('link', { name: 'Mastodon' });
		await expect(mastodon).toHaveAttribute('href', SOCIAL_LINKS.mastodon);
	});

	test('clicking a nav link navigates correctly', async ({ page }) => {
		await page.goto('/');
		await page.locator('nav.main-nav').getByRole('link', { name: 'About' }).click();
		await expect(page).toHaveURL('/about');
		await expect(page.getByRole('heading', { name: 'The Manifesto' })).toBeVisible();
	});
});
