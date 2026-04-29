import { test, expect } from '@playwright/test';

test.describe('Blog Post — first-post (has heroImage, readTime, tags)', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/blog/first-post/');
	});

	test('displays the post title', async ({ page }) => {
		await expect(page.locator('h1.post-title')).toContainText('First post');
	});

	test('displays the post description as lede', async ({ page }) => {
		await expect(page.locator('.post-lede')).toBeVisible();
	});

	test('displays the publication date', async ({ page }) => {
		const time = page.locator('.post-meta time').first();
		await expect(time).toBeVisible();
		await expect(time).toHaveAttribute('datetime', /^\d{4}-/);
	});

	test('displays read time', async ({ page }) => {
		await expect(page.locator('.meta-item.dim').first()).toContainText('min read');
	});

	test('displays tags', async ({ page }) => {
		await expect(page.locator('.tag-row')).toBeVisible();
		const tags = page.locator('.tag');
		await expect(tags).toHaveCount(2); // Security, Meta
	});

	test('renders hero image', async ({ page }) => {
		await expect(page.locator('.hero-image img')).toBeVisible();
	});

	test('renders post body content', async ({ page }) => {
		await expect(page.locator('.prose')).not.toBeEmpty();
	});

	test('back link navigates to /blog', async ({ page }) => {
		const backLink = page.getByRole('link', { name: /all articles/i });
		await expect(backLink).toBeVisible();
		await expect(backLink).toHaveAttribute('href', '/blog');
	});

	test('does NOT show updatedDate', async ({ page }) => {
		await expect(page.locator('.meta-item').filter({ hasText: 'Updated' })).toHaveCount(0);
	});
});

test.describe('Blog Post — using-mdx (MDX with embedded component)', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/blog/using-mdx/');
	});

	test('displays the post title', async ({ page }) => {
		await expect(page.locator('h1.post-title')).toContainText('Using MDX');
	});

	test('renders embedded HeaderLink component', async ({ page }) => {
		const embeddedLink = page.getByRole('link', { name: /embedded component in mdx/i });
		await expect(embeddedLink).toBeVisible();
	});

	test('displays MDX tags', async ({ page }) => {
		await expect(page.locator('.tag-row')).toBeVisible();
		await expect(page.locator('.tag').filter({ hasText: 'MDX' })).toBeVisible();
	});
});

test.describe('Blog Post — test-fixture (no heroImage, no readTime, no tags; has updatedDate)', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/blog/test-fixture/');
	});

	test('displays the post title', async ({ page }) => {
		await expect(page.locator('h1.post-title')).toContainText('Test Fixture Post');
	});

	test('does NOT render a hero image', async ({ page }) => {
		await expect(page.locator('.hero-image')).toHaveCount(0);
	});

	test('does NOT show a readTime entry', async ({ page }) => {
		await expect(page.locator('.meta-item.dim').filter({ hasText: 'read' })).toHaveCount(0);
	});

	test('does NOT show tags section', async ({ page }) => {
		await expect(page.locator('.tag-row')).toHaveCount(0);
	});

	test('shows updatedDate', async ({ page }) => {
		// The "Updated" label appears in meta when updatedDate is present
		await expect(page.locator('.meta-item').filter({ hasText: 'Updated' })).toBeVisible();
	});

	test('renders post body content', async ({ page }) => {
		await expect(page.locator('.prose')).not.toBeEmpty();
	});
});

test.describe('Blog Post — markdown-style-guide (rich markdown content)', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/blog/markdown-style-guide/');
	});

	test('displays the post title', async ({ page }) => {
		await expect(page.locator('h1.post-title')).toContainText('Markdown Style Guide');
	});

	test('renders a table in the post body', async ({ page }) => {
		await expect(page.locator('.prose table')).toBeVisible();
	});

	test('renders code blocks', async ({ page }) => {
		await expect(page.locator('.prose pre').first()).toBeVisible();
	});

	test('renders blockquote', async ({ page }) => {
		await expect(page.locator('.prose blockquote').first()).toBeVisible();
	});
});

test.describe('Blog Post — third-post (3 tags)', () => {
	test.beforeEach(async ({ page }) => {
		await page.goto('/blog/third-post/');
	});

	test('shows 3 tags: Frontend, CSP, Security', async ({ page }) => {
		await expect(page.locator('.tag').filter({ hasText: 'Frontend' })).toBeVisible();
		await expect(page.locator('.tag').filter({ hasText: 'CSP' })).toBeVisible();
		await expect(page.locator('.tag').filter({ hasText: 'Security' })).toBeVisible();
	});
});
