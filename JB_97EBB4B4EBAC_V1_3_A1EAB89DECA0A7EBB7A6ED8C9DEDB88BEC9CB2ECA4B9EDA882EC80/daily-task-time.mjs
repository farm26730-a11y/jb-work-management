const statuses = new Set(['planned', 'in_progress', 'hold', 'completed']);
const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const timePattern = /^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,6})?)?$/;
const instantPattern = /^(\d{4}-\d{2}-\d{2})[T ]((?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d)(?:\.(\d{1,6}))?(Z|[+-](?:[01]\d|2[0-3])(?::?[0-5]\d)?)$/;

function validDate(value) {
  if (typeof value !== 'string' || !datePattern.test(value)) return false;
  const at = Date.parse(value + 'T00:00:00Z');
  return Number.isFinite(at) && new Date(at).toISOString().slice(0, 10) === value;
}

// Integer microseconds retain Postgres event ordering within a millisecond.
function instant(value) {
  const match = typeof value === 'string' && instantPattern.exec(value);
  if (!match || !validDate(match[1])) return NaN;
  const [, date, time, fraction = '', zone] = match;
  const offset = zone.length === 3 ? zone + ':00' : zone;
  const at = Date.parse(date + 'T' + time + offset) * 1000 + Number(fraction.padEnd(6, '0'));
  return Number.isSafeInteger(at) ? at : NaN;
}

function iso(at) {
  const milliseconds = Math.floor(at / 1000);
  const remainder = String(at - milliseconds * 1000).padStart(3, '0');
  return new Date(milliseconds).toISOString().replace(/Z$/, remainder + 'Z');
}

function collectEvents(events, created, cutoff, coveredFrom, coveredThrough, issues) {
  const byId = new Map();
  const seen = new Set();
  const dated = [];
  let last = -Infinity;
  let ambiguous = false;
  for (const event of events) {
    const at = instant(event.changed_at);
    if (at > cutoff) continue;
    if (!Number.isFinite(at)) {
      issues.add('invalid_event_time');
      ambiguous = true;
      continue;
    }
    if (at < created) {
      issues.add('event_before_creation');
      continue;
    }
    if (at < coveredFrom || at > coveredThrough) continue;
    const signature = JSON.stringify([at, event.previous_status, event.new_status, event.changed_by]);
    if (event.id != null && byId.has(event.id) && byId.get(event.id) !== signature) {
      issues.add('conflicting_event_id');
      ambiguous = true;
    }
    if (event.id != null) byId.set(event.id, signature);
    if (seen.has(signature)) {
      issues.add('duplicate_event');
      continue;
    }
    seen.add(signature);
    if (at < last) issues.add('out_of_order');
    last = at;
    dated.push({ at, previous: event.previous_status, next: event.new_status, changedBy: event.changed_by ?? null });
  }
  dated.sort((a, b) => a.at - b.at);
  return { dated, ambiguous };
}

function taskSummary(task, events, coverage, start, cutoff) {
  const issues = new Set();
  const created = instant(task.created_at);
  if (created > cutoff) return null;
  const known = { planned: 0, in_progress: 0, hold: 0, completed: 0 };
  const segments = [];
  const completions = [];
  const transitions = [];
  let unknown = 0;
  const beginning = Number.isFinite(created) ? Math.max(start, created) : start;

  function add(from, to, state) {
    const clipped = Math.max(from, beginning);
    if (to <= clipped) return;
    if (state === null) unknown += to - clipped;
    else known[state] += to - clipped;
    segments.push({ from: iso(clipped), to: iso(to), status: state });
  }

  const from = instant(coverage?.from ?? task.created_at);
  const through = instant(coverage?.through);
  const coveredFrom = Math.max(created, from);
  const coveredThrough = Math.min(cutoff, through);
  const covered = coveredFrom <= coveredThrough;
  if (!Number.isFinite(created)) issues.add('invalid_creation_time');
  if (!covered || coveredFrom > beginning || coveredThrough < cutoff) issues.add('partial_history');
  const { dated, ambiguous } = collectEvents(events, created, cutoff, coveredFrom, coveredThrough, issues);
  let state = null;
  let completionUncertain = !covered || coveredFrom > beginning || coveredThrough < cutoff;

  if (!covered || ambiguous) {
    add(beginning, cutoff, null);
    completionUncertain = true;
  } else {
    add(beginning, coveredFrom, null);
    let cursor = coveredFrom;
    state = coveredFrom === created ? 'planned' : null;
    let terminal = false;
    if (coveredFrom > created && (dated[0]?.at ?? Infinity) > beginning) {
      issues.add('missing_start_state');
    }
    for (let i = 0; i < dated.length;) {
      const event = dated[i++];
      const { at, previous, next } = event;
      if (dated[i]?.at === at) {
        while (dated[i]?.at === at) i++;
        issues.add('conflicting_event_time');
        add(cursor, at, null);
        cursor = at;
        state = null;
        if (at >= start) completionUncertain = true;
        continue;
      }
      const valid = statuses.has(previous) && statuses.has(next) && previous !== next;
      const reopened = terminal || previous === 'completed';
      const mismatch = state !== null && state !== previous;
      if (!valid) issues.add('invalid_transition');
      if (reopened) issues.add('transition_after_completion');
      if (mismatch) issues.add('state_discontinuity');
      add(cursor, at, valid && !mismatch ? state : null);
      if ((!valid || reopened || mismatch) && at >= start) completionUncertain = true;
      if (valid && !reopened && at >= start) {
        const transition = { at: iso(at), from: previous, to: next, changedBy: event.changedBy };
        transitions.push(transition);
        if (next === 'completed') completions.push({ at: transition.at, changedBy: transition.changedBy });
      }
      cursor = at;
      terminal ||= previous === 'completed' || (valid && next === 'completed');
      state = valid && !reopened ? next : null;
    }
    // A later snapshot cannot validate a historical report without using future data.
    if (coveredThrough === cutoff && instant(task.status_as_of) === cutoff &&
        statuses.has(task.status) && state !== null && task.status !== state) {
      issues.add('snapshot_mismatch');
      state = null;
      completionUncertain = true;
    }
    add(cursor, coveredThrough, state);
    add(coveredThrough, cutoff, null);
    if (coveredThrough < cutoff) state = null;
  }

  return {
    taskId: task.id,
    assigneeId: task.assignee_id,
    assignmentVerified: task.assignmentVerified === true,
    registeredToday: Number.isFinite(created) ? created >= start : null,
    workedToday: known.in_progress > 0 ? true : unknown > 0 ? null : false,
    completedToday: completions.length > 0 ? true : completionUncertain || unknown > 0 ? null : false,
    completions,
    transitions,
    stateAtCutoff: state,
    runningMs: unknown > 0 ? null : known.in_progress / 1000,
    holdMs: unknown > 0 ? null : known.hold / 1000,
    knownStateMs: Object.fromEntries(Object.entries(known).map(([key, value]) => [key, value / 1000])),
    unknownMs: unknown / 1000,
    segments,
    issues: [...issues],
  };
}

/**
 * Summarize the employee's candidate tasks using DB rows and explicit coverage.
 * cutoffTime is an Asia/Seoul local time on date (HH:mm[:ss[.ffffff]]).
 * coverageByTask maps task ID to a contiguous, fully retrieved {from, through}
 * interval, inclusive of events at both endpoints. Omit from for creation.
 * Missing coverage stays unknown. task.status_as_of may certify a snapshot at
 * cutoff. Set task.assignmentVerified only with evidence of the employee's
 * assignment for the entire applicable window. Candidate tasks without that
 * evidence are returned separately so their time is never attributed.
 */
export function summarizeDailyTaskRows({ date, cutoffTime, tasks, history, coverageByTask = new Map() }) {
  if (!validDate(date) || typeof cutoffTime !== 'string' || !timePattern.test(cutoffTime)) {
    throw new RangeError('Expected a valid Seoul date and explicit local cutoff time');
  }
  const time = cutoffTime.length === 5 ? cutoffTime + ':00' : cutoffTime;
  const start = instant(date + 'T00:00:00+09:00');
  const cutoff = instant(date + 'T' + time + '+09:00');
  if (!Number.isFinite(start) || !Number.isFinite(cutoff)) throw new RangeError('Date outside supported range');

  const byTask = new Map();
  for (const entry of history) {
    if (!byTask.has(entry.task_id)) byTask.set(entry.task_id, []);
    byTask.get(entry.task_id).push(entry);
  }
  const rows = tasks.map(task =>
    taskSummary(task, byTask.get(task.id) ?? [], coverageByTask.get(task.id), start, cutoff)).filter(Boolean);
  return {
    date, timezone: 'Asia/Seoul', start: iso(start), cutoff: iso(cutoff),
    timeBasis: '업무 상태 기준 시간', holdReason: '원본 이력에서 구분할 수 없음',
    rows,
  };
}

export function summarizeDailyTaskTime({ employeeId, tasks, ...input }) {
  if (typeof employeeId !== 'string' || !employeeId.trim()) throw new TypeError('Expected an employee ID');
  const { rows, ...window } = summarizeDailyTaskRows({
    ...input, tasks: tasks.filter(task => task.assignee_id === employeeId),
  });
  return {
    employeeId, ...window,
    tasks: rows.filter(row => row.assignmentVerified),
    unverifiedAssignment: rows.filter(row => !row.assignmentVerified),
  };
}
