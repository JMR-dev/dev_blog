import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
	testDir: './e2e',
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 2 : 0,
	reporter: [['list'], ['html', { open: 'never' }]],
	use: {
		baseURL: 'http://localhost:4321',
		trace: 'on-first-retry',
	},
	projects: [
		{ name: 'chromium',       use: { ...devices['Desktop Chrome'] } },
		{ name: 'firefox',        use: { ...devices['Desktop Firefox'] } },
		{ name: 'webkit',         use: { ...devices['Desktop Safari'] } },
		{ name: 'mobile-chrome',  use: { ...devices['Pixel 5'] } },
		{ name: 'mobile-safari',  use: { ...devices['iPhone 14'] } },
	],
	webServer: {
		// --ignore-lock keeps `astro preview` in the foreground, where Playwright
		// can stop it. Without it, Astro 7 detaches into the background when an
		// AI agent runs it, and refuses to start while another preview holds the
		// lock file.
		command: 'pnpm build && pnpm preview --port 4321 --ignore-lock',
		url: 'http://localhost:4321',
		reuseExistingServer: !process.env.CI,
		timeout: 180_000,
	},
});
