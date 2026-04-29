import { test, expect } from '@playwright/test';
import { SITE_TITLE, PROJECTS } from '../src/consts';

test.describe('Projects Page', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/projects');
	});

	test('has correct page title', async ({ page }) => {
		await expect(page).toHaveTitle(`Projects · ${SITE_TITLE}`);
	});

	test('displays "Open Source" heading', async ({ page }) => {
		await expect(page.getByRole('heading', { name: 'Open Source', level: 1 })).toBeVisible();
	});

	test('displays lede paragraph with GitHub link', async ({ page }) => {
		const lede = page.locator('.lede');
		await expect(lede).toBeVisible();
		await expect(lede.getByRole('link', { name: 'GitHub' })).toBeVisible();
	});

	test('shows all projects', async ({ page }) => {
		for (const project of PROJECTS) {
			await expect(page.getByRole('heading', { name: project.name })).toBeVisible();
		}
	});

	test('shows all project descriptions', async ({ page }) => {
		for (const project of PROJECTS) {
			await expect(page.locator('.project-card p').filter({ hasText: project.description.slice(0, 30) })).toBeVisible();
		}
	});

	test('project cards link externally with correct security attributes', async ({ page }) => {
		const cards = page.locator('a.project-card');
		await expect(cards).toHaveCount(PROJECTS.length);

		for (let i = 0; i < PROJECTS.length; i++) {
			await expect(cards.nth(i)).toHaveAttribute('target', '_blank');
			await expect(cards.nth(i)).toHaveAttribute('rel', 'noopener noreferrer');
		}
	});

	test('each project card shows an arrow icon', async ({ page }) => {
		const arrows = page.locator('.project-arrow');
		await expect(arrows).toHaveCount(PROJECTS.length);
	});
});
