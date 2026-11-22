import { summarizeDailyTaskTime } from './daily-task-time.mjs';

const statuses = new Set(['planned', 'in_progress', 'hold', 'completed']);
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const utc = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const columns = {
  jb_tasks: { id: 'uuid!', assignee_id: 'uuid?', created_at: 'timestamptz!', status: 'text!' },
  jb_task_history: {
    id: 'uuid!', task_id: 'uuid!', changed_by: 'uuid?', previous_status: 'text?',
    new_status: 'text!', changed_at: 'timestamptz!',
  },
  jb_employees: { id: 'uuid!' },
};

function validId(value) {
  return typeof value === 'string' && uuid.test(value);
}

function validInstant(value) {
  if (typeof value !== 'string' || !utc.test(value)) return false;
  const at = Date.parse(value);
  return Number.isFinite(at) && new Date(at).toISOString().slice(0, 23) === value.slice(0, 23);
}

function compatible(schema, taskStatuses) {
  return Array.isArray(taskStatuses) && new Set(taskStatuses).size === statuses.size &&
    taskStatuses.every(status => statuses.has(status)) && Object.entries(columns).every(([table, expected]) =>
    Object.entries(expected).every(([column, type]) => schema?.[table]?.[column] === type));
}

function validTask(row, cutoff) {
  return row && validId(row.id) && (row.assignee_id === null || validId(row.assignee_id)) &&
    statuses.has(row.status) && validInstant(row.created_at) && row.created_at <= cutoff;
}

function validEvent(row, tasks, cutoff) {
  return row && validId(row.id) && tasks.has(row.task_id) &&
    (row.changed_by === null || validId(row.changed_by)) &&
    (row.previous_status === null || statuses.has(row.previous_status)) &&
    statuses.has(row.new_status) && validInstant(row.changed_at) && row.changed_at <= cutoff;
}

function failure(status, reason) {
  return { status, reason, report: null };
}

// Cursors are derived from rows, never trusted as an opaque next-page claim.
function readPages(source, scope, key, validate) {
  const { pages, count } = source ?? {};
  if (!Array.isArray(pages) || pages.length === 0 || !Number.isSafeInteger(count) || count < 0) {
    return failure('incomplete', 'missing_page_manifest');
  }
  const rows = [];
  const ids = new Set();
  let cursor = null;
  for (let i = 0; i < pages.length; i++) {
    const page = pages[i];
    if (page?.status === 'forbidden' || page?.status === 'error') {
      return failure(page.status, 'page_read_failed');
    }
    if (!page || page.status !== 'ok' || page.snapshotId !== scope ||
        page.after !== cursor || page.done !== (i === pages.length - 1) ||
        !Array.isArray(page.rows) || (page.rows.length === 0 && !page.done)) {
      return failure('incomplete', 'page_chain_mismatch');
    }
    for (const row of page.rows) {
      if (!validate(row)) return failure('incompatible', 'invalid_source_row');
      const next = key(row);
      if (ids.has(row.id) || (cursor !== null && next <= cursor)) {
        return failure('incomplete', 'duplicate_or_unordered_row');
      }
      rows.push(row);
      ids.add(row.id);
      cursor = next;
    }
  }
  if (rows.length !== count) return failure('incomplete', 'expected_count_mismatch');
  return { rows };
}

function readAssignments(ledger, snapshotId, taskIds) {
  const byTask = new Map();
  if (ledger === undefined) return byTask;
  if (ledger?.snapshotId !== snapshotId || !Array.isArray(ledger.periods)) return null;

  for (const period of ledger.periods) {
    if (!period || !taskIds.has(period.taskId) || !validId(period.employeeId) ||
        !validInstant(period.from) ||
        (period.to !== null && (!validInstant(period.to) || period.to <= period.from))) return null;
    if (!byTask.has(period.taskId)) byTask.set(period.taskId, []);
    byTask.get(period.taskId).push(period);
  }
  for (const periods of byTask.values()) {
    periods.sort((a, b) => a.from.localeCompare(b.from));
    for (let i = 1; i < periods.length; i++) {
      const end = periods[i - 1].to;
      if (end === null || end > periods[i].from) return null;
    }
  }
  return byTask;
}

// Durations stop at cutoff, but the engine also reports events exactly at cutoff.
function reportAssignee(periods, from, cutoff) {
  const first = periods.findIndex(period =>
    period.from <= from && (period.to === null || from < period.to));
  if (first === -1) return null;

  const employee = periods[first].employeeId;
  let end = periods[first].to;
  for (let i = first + 1; end !== null && end <= cutoff; i++) {
    const next = periods[i];
    // A period ending at cutoff does not cover the cutoff instant.
    if (!next || next.from !== end || next.employeeId !== employee) return null;
    end = next.to;
  }
  return employee;
}

/**
 * Adapt an envelope produced by an already-authorized server, or a local fixture.
 * The authorization marker describes that input contract; it does not authenticate
 * a caller or make a client-supplied envelope trustworthy.
 */
export function adaptDailyTaskSource({ date, cutoffTime, employeeId, source, assignmentLedger }) {
  if (!validId(employeeId)) throw new TypeError('Expected a canonical employee UUID');
  const emptyReport = summarizeDailyTaskTime({ date, cutoffTime, employeeId, tasks: [], history: [] });
  const { start, cutoff } = emptyReport;

  if (source?.status === 'forbidden' || source?.status === 'error') {
    return failure(source.status, 'source_read_failed');
  }
  if (source?.status !== 'ok' || source.authorization !== 'verified') {
    return failure('forbidden', 'report_scope_unverified');
  }
  if (source.contract !== 'jb-task-source-v1' || !compatible(source.schema, source.taskStatuses)) {
    return failure('incompatible', 'schema_mismatch');
  }
  if (source.scope !== 'all_tasks_created_through_cutoff_with_history' ||
      typeof source.snapshotId !== 'string' || !source.snapshotId.trim() ||
      !validInstant(source.asOf) || source.asOf < cutoff || source.cutoff !== cutoff) {
    return failure('incomplete', 'snapshot_scope_mismatch');
  }

  const tasks = readPages(source.tasks, source.snapshotId, row => row.id, row => validTask(row, cutoff));
  if (!tasks.rows) return tasks;
  const ids = new Set(tasks.rows.map(row => row.id));
  const history = readPages(source.history, source.snapshotId,
    row => row.changed_at + '/' + row.id, row => validEvent(row, ids, cutoff));
  if (!history.rows) return history;

  const assignments = readAssignments(assignmentLedger, source.snapshotId, ids);
  if (assignments === null) return failure('incompatible', 'invalid_assignment_ledger');

  const ownership = new Map();
  const candidates = tasks.rows.map(({ id, assignee_id, created_at, status }) => {
    const from = created_at > start ? created_at : start;
    const reportAssigneeId = reportAssignee(assignments.get(id) ?? [], from, cutoff);
    ownership.set(id, { currentAssigneeId: assignee_id, reportAssigneeId });
    return {
      id, assignee_id: reportAssigneeId ?? assignee_id, created_at, status,
      assignmentVerified: reportAssigneeId !== null, status_as_of: source.asOf,
    };
  });
  const events = history.rows.map(({ id, task_id, changed_by, previous_status, new_status, changed_at }) => ({
    id, task_id, changed_by, previous_status, new_status, changed_at,
  }));
  const coverageByTask = new Map(candidates.map(({ id, created_at }) => [id, { from: created_at, through: cutoff }]));
  const report = summarizeDailyTaskTime({ date, cutoffTime, employeeId, tasks: candidates, history: events, coverageByTask });
  const describe = row => ({ ...row, ...ownership.get(row.taskId) });
  report.tasks = report.tasks.map(describe);
  report.unverifiedAssignment = report.unverifiedAssignment.map(describe);
  return {
    status: ids.size === 0 ? 'empty' : 'ready',
    attribution: ids.size === 0 ? 'not_applicable' :
      candidates.every(row => row.assignmentVerified) ? 'verified' : 'unverified',
    unassignedTaskCount: tasks.rows.filter(row => row.assignee_id === null).length,
    report,
  };
}
