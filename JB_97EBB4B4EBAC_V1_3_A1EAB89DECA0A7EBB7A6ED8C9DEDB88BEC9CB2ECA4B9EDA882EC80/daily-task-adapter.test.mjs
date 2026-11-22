import assert from 'node:assert/strict';
import test from 'node:test';
import { adaptDailyTaskSource } from './daily-task-adapter.mjs';

const id = n => '00000000-0000-0000-0000-' + String(n).padStart(12, '0');
const employee = id(1);
const actor = id(2);
const snapshotId = 'synthetic-snapshot';
const cutoff = '2026-11-22T09:00:00.000000Z';
const task = { id: id(3), assignee_id: employee, status: 'completed', created_at: '2026-11-21T13:00:00.000000Z' };
const start = {
  id: id(4), task_id: task.id, changed_by: null, previous_status: 'planned',
  new_status: 'in_progress', changed_at: '2026-11-21T14:00:00.000000Z',
};
const complete = {
  id: id(5), task_id: task.id, changed_by: actor, previous_status: 'in_progress',
  new_status: 'completed', changed_at: '2026-11-22T02:00:00.000000Z',
};
const page = (rows, after = null, done = true) => ({ rows, after, done, snapshotId, status: 'ok' });
const cursor = row => row.changed_at + '/' + row.id;
const dataset = rows => ({ count: rows.length, pages: [page(rows)] });

function input() {
  return {
    date: '2026-11-22', cutoffTime: '18:00', employeeId: employee,
    source: {
      status: 'ok', authorization: 'verified', contract: 'jb-task-source-v1',
      scope: 'all_tasks_created_through_cutoff_with_history', snapshotId, cutoff, asOf: cutoff,
      taskStatuses: ['planned', 'in_progress', 'hold', 'completed'],
      schema: {
        jb_tasks: { id: 'uuid!', assignee_id: 'uuid?', created_at: 'timestamptz!', status: 'text!' },
        jb_task_history: {
          id: 'uuid!', task_id: 'uuid!', changed_by: 'uuid?', previous_status: 'text?',
          new_status: 'text!', changed_at: 'timestamptz!',
        },
        jb_employees: { id: 'uuid!' },
      },
      tasks: dataset([{ ...task }]),
      history: { count: 2, pages: [page([{ ...start }], null, false), page([{ ...complete }], cursor(start))] },
    },
  };
}

function expectFailure(input, status, reason) {
  assert.deepEqual(adaptDailyTaskSource(input), { status, reason, report: null });
}

test('01 same-snapshot pages feed the engine with prior state and a distinct actor', () => {
  const result = adaptDailyTaskSource(input());
  assert.equal(result.status, 'ready');
  assert.equal(result.attribution, 'unverified');
  assert.deepEqual(result.report.tasks, []);
  const [row] = result.report.unverifiedAssignment;
  assert.equal(row.runningMs, 11 * 60 * 60 * 1000);
  assert.equal(row.completedToday, true);
  assert.deepEqual(row.completions, [{ at: complete.changed_at, changedBy: actor }]);
  assert.equal(row.assigneeId, employee);
});

test('02 raw assignment flags are ignored, and null assignees are counted separately', () => {
  const request = input();
  request.source.tasks = dataset([
    { ...task, assignmentVerified: true },
    { ...task, id: id(6), assignee_id: null },
  ]);
  const result = adaptDailyTaskSource(request);
  assert.deepEqual(result.report.tasks, []);
  assert.equal(result.report.unverifiedAssignment.length, 1);
  assert.equal(result.unassignedTaskCount, 1);
});

test('03 added source columns are compatible', () => {
  const request = input();
  request.source.schema.jb_tasks.new_field = 'text?';
  request.source.tasks.pages[0].rows[0].new_field = 'synthetic';
  assert.equal(adaptDailyTaskSource(request).status, 'ready');
});

test('04 detects removed fields and changed ID type/nullability even for zero rows', () => {
  for (const mutate of [
    schema => delete schema.jb_tasks.assignee_id,
    schema => { schema.jb_employees.id = 'text!'; },
    schema => { schema.jb_task_history.changed_by = 'uuid!'; },
  ]) {
    const request = input();
    request.source.tasks = dataset([]);
    request.source.history = dataset([]);
    mutate(request.source.schema);
    expectFailure(request, 'incompatible', 'schema_mismatch');
  }
});

test('05 rejects unknown task and history status values and missing projected fields', () => {
  for (const mutate of [
    source => { source.tasks.pages[0].rows[0].status = 'paused'; },
    source => { source.history.pages[1].rows[0].new_status = 'closed'; },
    source => { delete source.history.pages[1].rows[0].previous_status; },
  ]) {
    const request = input();
    mutate(request.source);
    expectFailure(request, 'incompatible', 'invalid_source_row');
  }
});

test('06 detects missing final page, broken cursor, changed snapshot and count disagreement', () => {
  for (const mutate of [
    history => history.pages.pop(),
    history => { history.pages[1].after = null; },
    history => { history.pages[1].snapshotId = 'different'; },
  ]) {
    const request = input();
    mutate(request.source.history);
    expectFailure(request, 'incomplete', 'page_chain_mismatch');
  }
  const request = input();
  request.source.history.count = 3;
  expectFailure(request, 'incomplete', 'expected_count_mismatch');
});

test('07 detects duplicate IDs, including when timestamps differ', () => {
  const request = input();
  request.source.history.pages[1].rows[0].id = start.id;
  expectFailure(request, 'incomplete', 'duplicate_or_unordered_row');
});

test('08 confirmed source zero differs from an empty inbox, read failure and permissions failure', () => {
  const request = input();
  request.source.tasks = dataset([]);
  request.source.history = dataset([]);
  assert.equal(adaptDailyTaskSource(request).status, 'empty');
  expectFailure({ ...request, source: undefined }, 'forbidden', 'report_scope_unverified');
  expectFailure({ ...request, source: { ...request.source, authorization: undefined } }, 'forbidden', 'report_scope_unverified');
  for (const status of ['error', 'forbidden']) {
    expectFailure({ ...request, source: { status } }, status, 'source_read_failed');
    const partial = input();
    partial.source.history.pages[1] = { status };
    expectFailure(partial, status, 'page_read_failed');
  }
  request.source.history.pages = [];
  expectFailure(request, 'incomplete', 'missing_page_manifest');
});

test('09 rejects a mismatched report cutoff or snapshot older than cutoff', () => {
  for (const field of ['cutoff', 'asOf']) {
    const request = input();
    request.source[field] = '2026-11-22T08:59:59.999999Z';
    expectFailure(request, 'incomplete', 'snapshot_scope_mismatch');
  }
});

test('10 rejects orphan history and noncanonical or out-of-window timestamps', () => {
  for (const patch of [
    { task_id: id(90) },
    { changed_at: '2026-11-22T09:00:00.000001Z' },
    { changed_at: '2026-11-22T02:00:00+00:00' },
  ]) {
    const request = input();
    Object.assign(request.source.history.pages[1].rows[0], patch);
    expectFailure(request, 'incompatible', 'invalid_source_row');
  }
});

test('11 tied cursor timestamps do not establish transition order', () => {
  const request = input();
  request.source.history.pages[1].rows[0].changed_at = start.changed_at;
  const result = adaptDailyTaskSource(request);
  assert.equal(result.status, 'ready');
  const [row] = result.report.unverifiedAssignment;
  assert.equal(row.runningMs, null);
  assert.ok(row.issues.includes('conflicting_event_time'));
});

test('12 zero candidates for one employee is still unverified attribution', () => {
  const request = input();
  request.employeeId = id(9);
  const result = adaptDailyTaskSource(request);
  assert.equal(result.status, 'ready');
  assert.equal(result.attribution, 'unverified');
  assert.deepEqual(result.report.unverifiedAssignment, []);
});

test('13 checks task status constraint even with no rows', () => {
  const request = input();
  request.source.tasks = dataset([]);
  request.source.history = dataset([]);
  request.source.taskStatuses.push('paused');
  expectFailure(request, 'incompatible', 'schema_mismatch');
});

test('14 full historical assignment takes precedence over a different current assignee', () => {
  const request = input();
  request.source.asOf = '2026-11-22T10:00:00.000000Z';
  request.source.tasks.pages[0].rows[0].assignee_id = actor;
  request.assignmentLedger = { snapshotId, periods: [
    { taskId: task.id, employeeId: employee, from: task.created_at, to: '2026-11-22T09:30:00.000000Z' },
    { taskId: task.id, employeeId: actor, from: '2026-11-22T09:30:00.000000Z', to: null },
  ] };
  const [row] = adaptDailyTaskSource(request).report.tasks;
  assert.equal(row.reportAssigneeId, employee);
  assert.equal(row.currentAssigneeId, actor);
  assert.equal(row.runningMs, 660 * 60_000);
  const current = adaptDailyTaskSource({ ...request, employeeId: actor }).report;
  assert.deepEqual(current.tasks, []);
  assert.deepEqual(current.unverifiedAssignment, []);
});

test('15 missing, partial, and split assignment evidence cannot enter confirmed totals', () => {
  for (const periods of [
    [],
    [{ taskId: task.id, employeeId: employee, from: task.created_at, to: cutoff }],
    [
      { taskId: task.id, employeeId: employee, from: task.created_at, to: complete.changed_at },
      { taskId: task.id, employeeId: actor, from: complete.changed_at, to: null },
    ],
  ]) {
    const request = input();
    request.assignmentLedger = { snapshotId, periods };
    const { report } = adaptDailyTaskSource(request);
    assert.deepEqual(report.tasks, []);
    assert.equal(report.unverifiedAssignment[0].currentAssigneeId, employee);
    assert.equal(report.unverifiedAssignment[0].reportAssigneeId, null);
  }
});

test('16 adjacent proof for the same employee is accepted, but gaps and overlaps are not', () => {
  const request = input();
  const first = { taskId: task.id, employeeId: employee, from: task.created_at, to: complete.changed_at };
  const second = { taskId: task.id, employeeId: employee, from: complete.changed_at, to: null };
  request.assignmentLedger = { snapshotId, periods: [second, first] };
  assert.equal(adaptDailyTaskSource(request).report.tasks.length, 1);
  second.from = cutoff;
  assert.equal(adaptDailyTaskSource(request).report.unverifiedAssignment.length, 1);
  second.from = task.created_at;
  expectFailure(request, 'incompatible', 'invalid_assignment_ledger');
  request.assignmentLedger.snapshotId = 'other-snapshot';
  expectFailure(request, 'incompatible', 'invalid_assignment_ledger');
});

test('17 assignment ending exactly at cutoff leaves an exact-cutoff completion unverified', () => {
  const request = input();
  request.source.history.pages[1].rows[0].changed_at = cutoff;
  request.assignmentLedger = { snapshotId, periods: [
    { taskId: task.id, employeeId: employee, from: task.created_at, to: cutoff },
  ] };
  const { report } = adaptDailyTaskSource(request);
  assert.deepEqual(report.tasks, []);
  const [row] = report.unverifiedAssignment;
  assert.equal(row.reportAssigneeId, null);
  assert.deepEqual(row.completions, [{ at: cutoff, changedBy: actor }]);
});

test('18 reassignment and completion at cutoff do not enter either employee’s confirmed results', () => {
  const request = input();
  request.source.tasks.pages[0].rows[0].assignee_id = actor;
  request.source.history.pages[1].rows[0].changed_at = cutoff;
  request.assignmentLedger = { snapshotId, periods: [
    { taskId: task.id, employeeId: employee, from: task.created_at, to: cutoff },
    { taskId: task.id, employeeId: actor, from: cutoff, to: null },
  ] };
  const earlier = adaptDailyTaskSource(request).report;
  const current = adaptDailyTaskSource({ ...request, employeeId: actor }).report;
  assert.deepEqual(earlier.tasks, []);
  assert.deepEqual(current.tasks, []);
  assert.equal(current.unverifiedAssignment[0].completedToday, true);
  assert.equal(current.unverifiedAssignment[0].reportAssigneeId, null);
});

test('19 contiguous same-assignee evidence beginning at cutoff confirms cutoff events', () => {
  const request = input();
  request.source.history.pages[1].rows[0].changed_at = cutoff;
  request.assignmentLedger = { snapshotId, periods: [
    { taskId: task.id, employeeId: employee, from: task.created_at, to: cutoff },
    { taskId: task.id, employeeId: employee, from: cutoff, to: null },
  ] };
  const { report } = adaptDailyTaskSource(request);
  assert.deepEqual(report.unverifiedAssignment, []);
  assert.equal(report.tasks[0].reportAssigneeId, employee);
  assert.deepEqual(report.tasks[0].completions, [{ at: cutoff, changedBy: actor }]);

  request.assignmentLedger.periods[0].to = '2026-11-22T08:59:59.999999Z';
  assert.equal(adaptDailyTaskSource(request).report.unverifiedAssignment[0].reportAssigneeId, null);
});
