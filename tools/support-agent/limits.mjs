// Recognizes when Claude Code refuses because of the account (usage limit reached, subscription not usable), so the
// support agent waits until the limit resets instead of retrying every few minutes.

/** Claude can't answer right now for an account reason; `resetAt` (ms) is when to try again, if the message said. */
export class LimitError extends Error {
  constructor(message, resetAt) {
    super(message);
    this.name = 'LimitError';
    this.resetAt = resetAt ?? null;
  }
}

const LIMIT = /usage limit|limit reached|session limit|hit your .{0,20}limit|rate limit|can't use your claude subscription|payment is past due/i;

/** A LimitError for this output of `claude`, or null when it's another kind of failure. */
export function limitError(text, now = Date.now()) {
  if (!text || !LIMIT.test(text)) return null;
  const line = text.split('\n').find(l => LIMIT.test(l)) || text;
  return new LimitError(line.trim().slice(0, 300), resetTime(text, now));
}

/** When the limit resets: "…|1793650000" (epoch seconds), or "resets 1:50pm (Asia/Jerusalem)" / "resets 3pm". */
export function resetTime(text, now = Date.now()) {
  const epoch = /\|(\d{10})\b/.exec(text);
  if (epoch) return Number(epoch[1]) * 1000;
  const m = /resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([^)]+)\))?/i.exec(text);
  if (!m) return null;
  let hour = Number(m[1]) % 12;
  if (!m[3]) hour = Number(m[1]);
  else if (m[3].toLowerCase() === 'pm') hour += 12;
  const minute = Number(m[2] || 0);
  if (hour > 23 || minute > 59) return null;
  return nextTime(hour, minute, m[4], now);
}

/** The next moment (ms) at hour:minute in the given time zone (the computer's own when missing or unknown). */
function nextTime(hour, minute, zone, now) {
  let offset = 0; // zone time − UTC, in ms, around now
  if (zone) {
    try {
      const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
        timeZone: zone, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric',
        hour: 'numeric', minute: 'numeric', second: 'numeric',
      }).formatToParts(new Date(now)).map(p => [p.type, p.value]));
      const asUTC = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
      offset = asUTC - Math.floor(now / 1000) * 1000;
      const day = Date.UTC(parts.year, parts.month - 1, parts.day, hour, minute) - offset;
      return day > now ? day : day + 24 * 3600 * 1000;
    } catch {
      // Unknown zone: fall through to local time.
    }
  }
  const d = new Date(now);
  d.setHours(hour, minute, 0, 0);
  return d.getTime() > now ? d.getTime() : d.getTime() + 24 * 3600 * 1000;
}
