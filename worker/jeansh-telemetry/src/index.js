/**
 * jeansh-telemetry: the two things Jeansh sends that are not crashes.
 *
 *   POST /ping   — one line a day from an install, so we know how many people
 *                  run Jeansh. Install id, version, build, platform, OS. That
 *                  is the whole of it, and the Worker refuses a body with
 *                  anything else in it rather than storing what it was not
 *                  asked for.
 *   POST /issue  — a bug report somebody chose to send without their name on
 *                  it. This Worker holds the GitHub token and opens the issue
 *                  as a bot; the app holds no token, because the app is a
 *                  public repository and anything baked into it is readable
 *                  with `strings`.
 *
 * Nothing here is authenticated. /issue is a public write surface onto a
 * public issue tracker, so it is rate limited per install and per IP, capped
 * in size, and can be switched off in the database without a deploy. See
 * README.md for what that does and does not protect against.
 */

/** The most a request body may be, before it is even parsed. */
const MAX_BODY = 16 * 1024;

/** Caps on what a report may carry, matching the app's own. */
const MAX_TITLE = 200;
const MAX_REPORT = 8000;

/** Reports a day, by install id and by IP. */
const PER_INSTALL = 3;
const PER_IP = 5;

/** Where anonymous reports land. */
const REPO = 'triasbrata/sshbox';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'POST') return text(405, 'POST only');
    try {
      if (url.pathname === '/ping') return await ping(request, env);
      if (url.pathname === '/issue') return await issue(request, env);
    } catch (error) {
      // Never the error's own text: it can quote the body it was parsing.
      console.log(`${url.pathname} failed: ${error && error.name}`);
      return text(500, 'something went wrong here');
    }
    return text(404, 'no such thing');
  },
};

function text(status, body) {
  return new Response(body, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8' },
  });
}

/** The body as JSON, or null if it is too big or is not JSON at all. */
async function read(request) {
  const size = Number(request.headers.get('content-length') || 0);
  if (size > MAX_BODY) return null;
  const body = await request.text();
  if (body.length > MAX_BODY) return null;
  try {
    const parsed = JSON.parse(body);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed
      : null;
  } catch {
    return null;
  }
}

/** A string field, trimmed and cut, or '' if it is not a string. */
function field(value, max) {
  return typeof value === 'string' ? value.slice(0, max).trim() : '';
}

/** Today, UTC, as YYYY-MM-DD: the day a count and a quota are kept by. */
function today() {
  return new Date().toISOString().slice(0, 10);
}

/**
 * One install, once a day.
 *
 * `INSERT OR IGNORE` on (day, install) is the whole of the deduplication: the
 * app already asks only once a day, and this makes a second ask — a clock that
 * moved, an install restored from a backup — cost one ignored write rather
 * than a double count.
 */
async function ping(request, env) {
  const body = await read(request);
  if (!body) return text(400, 'no');
  const install = field(body.install, 64);
  // A UUID and nothing else: not a device id, not anything with a shape we
  // did not ask for.
  if (!/^[0-9a-f-]{36}$/.test(install)) return text(400, 'no');

  await env.DB.prepare(
    `INSERT OR IGNORE INTO pings (day, install, version, build, platform, os)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      today(),
      install,
      field(body.version, 32),
      field(body.build, 32),
      field(body.platform, 32),
      field(body.os, 200),
    )
    .run();
  return new Response(null, { status: 204 });
}

/**
 * An anonymous bug report, opened on GitHub by the bot the token belongs to.
 *
 * The order matters: the switch, then the quotas, then GitHub. A refused
 * report never reaches GitHub and never costs a token call.
 */
async function issue(request, env) {
  if (await flag(env, 'issues_off')) return text(403, 'switched off');

  const body = await read(request);
  if (!body) return text(400, 'no');
  const install = field(body.install, 64);
  if (!/^[0-9a-f-]{36}$/.test(install)) return text(400, 'no');
  const title = field(body.title, MAX_TITLE);
  const report = field(body.body, MAX_REPORT);
  if (!title || !report) return text(400, 'no');

  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  if (!(await take(env, `install:${install}`, PER_INSTALL))) {
    return text(429, 'enough for today');
  }
  if (!(await take(env, `ip:${ip}`, PER_IP))) {
    return text(429, 'enough for today');
  }

  const answer = await fetch(`https://api.github.com/repos/${REPO}/issues`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      accept: 'application/vnd.github+json',
      'user-agent': 'jeansh-telemetry',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      title,
      // The notice is the Worker's, not the app's, so a maintainer can trust
      // it: whatever the app sent, an issue opened through here says where it
      // came from and that nobody can be written back to.
      body:
        `${report}\n\n---\n` +
        '_Opened by Jeansh’s anonymous bug relay. The reporter left no ' +
        'name and cannot be replied to. Everything above was written by ' +
        'whoever sent it._',
      labels: ['anonymous-report'],
    }),
  });
  if (!answer.ok) {
    console.log(`github said ${answer.status}`);
    return text(502, 'github would not take it');
  }
  const made = await answer.json();
  return Response.json({ url: made.html_url });
}

/**
 * Takes one off today's allowance for [key], and says whether there was one.
 *
 * ponytail: two requests arriving together can both read the same count and
 * both write, so a burst can go one or two past the limit. A Durable Object
 * would make it exact; at these numbers the cap is a brake on a flood, not a
 * ledger, and one extra issue is not worth the machinery.
 */
async function take(env, key, allowed) {
  const day = today();
  const row = await env.DB.prepare(
    'SELECT n FROM quota WHERE bucket = ? AND day = ?',
  )
    .bind(key, day)
    .first();
  const used = row ? row.n : 0;
  if (used >= allowed) return false;
  await env.DB.prepare(
    `INSERT INTO quota (bucket, day, n) VALUES (?, ?, 1)
     ON CONFLICT (bucket) DO UPDATE SET
       n = CASE WHEN quota.day = excluded.day THEN quota.n + 1 ELSE 1 END,
       day = excluded.day`,
  )
    .bind(key, day)
    .run();
  return true;
}

/**
 * A switch kept in the database rather than in the environment, so turning
 * anonymous reports off is one `wrangler d1 execute` and takes effect at the
 * next request — no deploy, nothing to rebuild, at three in the morning.
 */
async function flag(env, name) {
  const row = await env.DB.prepare('SELECT on_ FROM flags WHERE name = ?')
    .bind(name)
    .first();
  return !!(row && row.on_);
}
