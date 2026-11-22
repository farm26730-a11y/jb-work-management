import assert from 'node:assert/strict';
import test from 'node:test';
import { createDailyReportReader } from './daily-report-server.mjs';
import { date, cutoffTime, staff, source, assignmentLedger } from './daily-report-preview-fixture.mjs';

const authUserId = '00000000-0000-0000-0000-000000000090';
const ownerId = '00000000-0000-0000-0000-000000000091';
const verified = { userId: authUserId };
const owner = { auth_user_id: authUserId, id: ownerId, active: true, app_role: 'owner' };
const request = { session: 'synthetic-session', employeeId: staff[0].id, date, cutoffTime };

function fixture({ matches = [owner], envelope = { source, assignmentLedger }, target } = {}) {
  const calls = [];
  const reader = createDailyReportReader({
    verifyAccessToken: async session => {
      calls.push('auth');
      return session === request.session ? verified : null;
    },
    withReadOnlySnapshot: async work => {
      calls.push('snapshot');
      return work({
        findEmployeesByAuthUserId: async id => {
          calls.push('caller');
          assert.equal(id, authUserId);
          return matches;
        },
        findEmployeeById: async id => {
          calls.push('target');
          return target === undefined ? staff.find(person => person.id === id) ?? null : target;
        },
        readReportSource: async ({ employeeId, start, cutoff }) => {
          calls.push('report');
          assert.ok(staff.some(person => person.id === employeeId));
          assert.equal(start, '2026-11-21T15:00:00.000000Z');
          assert.equal(cutoff, source.cutoff);
          return envelope;
        },
      });
    },
  });
  return { calls, reader };
}

test('unwired server does not accept self-declared authentication', async () => {
  assert.deepEqual(await createDailyReportReader()({ ...request, authorization: 'verified' }),
    { status: 'not_implemented', report: null });
});

test('missing or whitespace token never invokes the verifier or snapshot', async () => {
  const { reader, calls } = fixture();
  for (const session of [null, undefined, '   ']) {
    assert.equal((await reader({ ...request, session })).status, 'unauthenticated');
  }
  assert.deepEqual(calls, []);
});

test('invalid or tampered token does not reach the snapshot', async () => {
  const { reader, calls } = fixture();
  const result = await reader({ ...request, session: 'synthetic-tampered-token', userId: authUserId });
  assert.deepEqual(result, { status: 'unauthenticated', report: null });
  assert.deepEqual(calls, ['auth']);
});

test('inactive owner is rejected before target or work data are read', async () => {
  const { reader, calls } = fixture({ matches: [{ ...owner, active: false }] });
  assert.equal((await reader(request)).status, 'forbidden');
  assert.deepEqual(calls, ['auth', 'snapshot', 'caller']);
});

test('manager and staff cannot acquire report access through request fields', async () => {
  for (const app_role of ['manager', 'staff']) {
    const { reader, calls } = fixture({ matches: [{ ...owner, app_role }] });
    const result = await reader({
      ...request, employeeId: staff[1].id, actorEmployeeId: ownerId,
      role: 'owner', authorization: 'verified',
    });
    assert.deepEqual(result, { status: 'forbidden', report: null });
    assert.deepEqual(calls, ['auth', 'snapshot', 'caller']);
  }
});

test('missing, duplicate and mismatched account links are rejected', async () => {
  for (const matches of [[], [owner, owner], [{ ...owner, auth_user_id: staff[0].id }]]) {
    const { reader, calls } = fixture({ matches });
    assert.equal((await reader(request)).status, 'forbidden');
    assert.deepEqual(calls, ['auth', 'snapshot', 'caller']);
  }
});

test('active owner can request either verified target within one snapshot callback', async () => {
  for (const person of staff) {
    const { reader, calls } = fixture();
    const result = await reader({ ...request, employeeId: person.id, source: { status: 'error' } });
    assert.equal(result.status, 'ready');
    assert.equal(result.report.employeeId, person.id);
    assert.equal(result.report.timezone, 'Asia/Seoul');
    assert.deepEqual(calls, ['auth', 'snapshot', 'caller', 'target', 'report']);
  }
});

test('malformed, unknown and mismatched target IDs never reach work data', async () => {
  const malformed = fixture();
  assert.equal((await malformed.reader({ ...request, employeeId: 'not-an-id' })).status, 'invalid_request');
  assert.deepEqual(malformed.calls, ['auth']);

  const unknown = fixture();
  assert.equal((await unknown.reader({ ...request, employeeId: ownerId })).status, 'not_found');
  assert.deepEqual(unknown.calls, ['auth', 'snapshot', 'caller', 'target']);

  const mismatch = fixture({ target: staff[1] });
  assert.equal((await mismatch.reader(request)).status, 'error');
  assert.deepEqual(mismatch.calls, ['auth', 'snapshot', 'caller', 'target']);
});

test('invalid Seoul date or cutoff is rejected before opening a snapshot', async () => {
  for (const invalid of [{ date: '2026-02-30' }, { cutoffTime: '24:00' }]) {
    const { reader, calls } = fixture();
    assert.equal((await reader({ ...request, ...invalid })).status, 'invalid_request');
    assert.deepEqual(calls, ['auth']);
  }
});

test('a complete empty snapshot differs from provider failure and denial', async () => {
  const empty = { count: 0, pages: [{ status: 'ok', snapshotId: source.snapshotId, after: null, done: true, rows: [] }] };
  for (const [snapshotSource, status] of [
    [{ ...source, tasks: empty, history: empty }, 'empty'],
    [{ status: 'error' }, 'error'],
    [{ status: 'forbidden' }, 'forbidden'],
  ]) {
    const { reader } = fixture({ envelope: { source: snapshotSource } });
    const result = await reader(request);
    assert.equal(result.status, status);
    assert.equal(result.report === null, status !== 'empty');
  }
});

test('missing pages and divergent snapshot IDs never produce totals', async () => {
  for (const history of [
    { ...source.history, count: source.history.count + 1 },
    { ...source.history, pages: [] },
    { ...source.history, pages: [{ ...source.history.pages[0], snapshotId: 'synthetic-other-snapshot' }] },
  ]) {
    const { reader } = fixture({ envelope: { source: { ...source, history } } });
    assert.equal((await reader(request)).status, 'incomplete');
    assert.equal((await reader(request)).report, null);
  }
});

test('source contract changes are visible and later current state does not rewrite cutoff state', async () => {
  const changed = fixture({ envelope: { source: { ...source, taskStatuses: ['planned', 'paused'] } } });
  assert.equal((await changed.reader(request)).status, 'incompatible');

  const later = fixture();
  const result = await later.reader({ ...request, employeeId: staff[1].id });
  const row = result.report.unverifiedAssignment.find(work => work.runningMs === 1080 * 60_000);
  assert.equal(row.stateAtCutoff, 'in_progress');
  assert.equal(row.completedToday, false);
});

test('missing reassignment ledger keeps candidates out of confirmed work', async () => {
  const { reader } = fixture({ envelope: { source } });
  const result = await reader(request);
  assert.deepEqual(result.report.tasks, []);
  assert.ok(result.report.unverifiedAssignment.length > 0);
  assert.ok(result.report.unverifiedAssignment.every(row => row.reportAssigneeId === null));
});

test('provider and snapshot exceptions do not expose underlying details', async () => {
  const fail = async () => { throw new Error('synthetic provider detail'); };
  for (const options of [
    { verifyAccessToken: fail, withReadOnlySnapshot: fail },
    { verifyAccessToken: async () => verified, withReadOnlySnapshot: fail },
  ]) {
    assert.deepEqual(await createDailyReportReader(options)(request), { status: 'error', report: null });
  }
});

test('all tested work and employee records are synthetic', () => {
  const prefix = '00000000-0000-0000-0000-';
  const ids = [authUserId, ownerId, ...staff.map(person => person.id),
    ...source.tasks.pages.flatMap(page => page.rows.flatMap(row => [row.id, row.assignee_id])),
    ...source.history.pages.flatMap(page => page.rows.flatMap(row => [row.id, row.task_id, row.changed_by])),
    ...assignmentLedger.periods.flatMap(row => [row.taskId, row.employeeId])];
  assert.ok(ids.every(id => id === null || id.startsWith(prefix)));
});
