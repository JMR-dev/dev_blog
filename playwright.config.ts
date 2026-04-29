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
		command: 'pnpm build && pnpm preview --port 4321',
		url: 'http://localhost:4321',
		reuseExistingServer: !process.env.CI,
		timeout: 180_000,
	},
});
