// Draws Play's store graphics from src/*.html on a canvas in headless
// Chromium, saves them here, and checks each PNG against Play's rules.
// Run from this folder: bun install && bun run generate
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url))

const jobs = [
  // 32-bit PNG, at most 1 MB.
  { src: 'src/icon.html', out: 'icon-512.png', width: 512, height: 512, alpha: true, maxBytes: 1 << 20 },
  // 24-bit PNG with no alpha, at most 15 MB.
  { src: 'src/feature-graphic.html', out: 'feature-graphic-1024x500.png', width: 1024, height: 500, alpha: false, maxBytes: 15 << 20 },
]

// The flag lets a canvas that drew a file:// picture still export its pixels.
const browser = await chromium.launch({ args: ['--allow-file-access-from-files'] })
try {
  for (const job of jobs) {
    const page = await browser.newPage({
      viewport: { width: job.width, height: job.height },
      deviceScaleFactor: 1,
    })
    const errors: string[] = []
    page.on('pageerror', (e) => errors.push(e.message))
    page.on('requestfailed', (r) => errors.push(`${r.url()}: ${r.failure()?.errorText}`))
    await page.goto(new URL(job.src, import.meta.url).href)
    await page
      .waitForFunction(() => document.body.dataset.ready, null, { timeout: 10_000 })
      .catch(() => {
        throw new Error(`${job.src}: ${errors.join('; ') || 'never finished drawing'}`)
      })
    if (job.alpha) {
      // Chromium saves an opaque screenshot as 24-bit RGB, even with
      // omitBackground; the canvas's own PNG is always RGBA.
      const url = await page.evaluate(() => document.querySelector('canvas')!.toDataURL('image/png'))
      writeFileSync(here(job.out), Buffer.from(url.slice(url.indexOf(',') + 1), 'base64'))
    } else {
      await page.screenshot({ path: here(job.out) })
    }
    await page.close()
    check(job)
  }
} finally {
  await browser.close()
}

// A PNG's IHDR: width and height at bytes 16 and 20, bit depth at 24, colour
// type at 25 (2 is RGB, 6 is RGBA).
function check(job: (typeof jobs)[number]) {
  const png = readFileSync(here(job.out))
  const [w, h, depth, type] = [png.readUInt32BE(16), png.readUInt32BE(20), png[24], png[25]]
  const want = job.alpha ? 6 : 2
  const ok = w === job.width && h === job.height && depth === 8 && type === want && png.length <= job.maxBytes
  const kind = type === 6 ? 'RGBA, 32-bit' : type === 2 ? 'RGB, 24-bit, no alpha' : `colour type ${type}`
  console.log(`${ok ? 'ok ' : 'BAD'} ${job.out}: ${w} × ${h}, ${kind}, ${png.length} bytes (${(png.length / 1024).toFixed(1)} KB)`)
  if (!ok) process.exitCode = 1
}
