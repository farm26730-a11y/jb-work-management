import assert from 'node:assert/strict';
import test from 'node:test';
import { createSupabaseTokenVerifier, jbDevProject } from './daily-report-auth.mjs';
import { createJbDevDailyReportReader } from './daily-report-jb-dev.mjs';
import { date, cutoffTime, source, staff } from './daily-report-preview-fixture.mjs';

const id = n => '00000000-0000-0000-0000-' + String(n).padStart(12, '0');
const authId = id(90);
const url = 'https://' + jbDevProject + '.supabase.co';
const key = 'sb_' + 'publishable_' + 'synthetic';
const issuer = url + '/auth/v1';
const env = {
  JB_REPORT_SUPABASE_URL: url,
  JB_REPORT_SUPABASE_PUBLISHABLE_KEY: key,
  JB_REPORT_DATABASE_URL: 'postgresql://synthetic_reader@db.' + jbDevProject + '.supabase.co/postgres?sslmode=verify-full',
};
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
function token(fields = {}) {
  return encode({ alg: 'synthetic' }) + '.' + encode({
    sub: authId, iss: issuer, exp: Math.floor(Date.now() / 1000) + 3600, ...fields,
  }) + '.synthetic';
}
const request = { date, cutoffTime, employeeId: staff[0].id, session: token() };

test('Auth calls the configured provider, even for locally plausible claims', async () => {
  const verify = createSupabaseTokenVerifier({ url, publishableKey: key, fetchUser: async (endpoint, options) => {
    assert.equal(endpoint, issuer + '/user');
    assert.equal(options.headers.Authorization, 'Bearer ' + request.session);
    assert.equal(options.headers.apikey, key);
    assert.equal(options.redirect, 'error');
    return Response.json({ id: authId, role: 'untrusted' });
  } });
  assert.deepEqual(await verify(request.session), { userId: authId });
});

test('Auth rejects expired, foreign and malformed tokens before requests', async () => {
  const verify = createSupabaseTokenVerifier({ url, publishableKey: key, fetchUser: () => assert.fail('unexpected network call') });
  for (const value of [
    token({ exp: 1 }), token({ iss: 'https://synthetic-foreign.supabase.co/auth/v1' }), 'invalid',
  ]) assert.equal(await verify(value), null);
});

test('Auth provider denial, different subject and provider error remain distinct', async () => {
  let response;
  const verify = createSupabaseTokenVerifier({ url, publishableKey: key, fetchUser: async () => response });
  for (const status of [401, 403]) {
    response = new Response(null, { status });
    assert.equal(await verify(request.session), null);
  }
  response = Response.json({ id: id(91) });
  assert.equal(await verify(request.session), null);
  response = new Response(null, { status: 503 });
  await assert.rejects(verify(request.session), /provider lookup failed/);
});

test('missing config is not implemented; rejecting foreign projects and insecure DSNs never opens a connection', async () => {
  const fetchUser = () => assert.fail('unexpected network call');
  const incomplete = { ...env };
  delete incomplete.JB_REPORT_DATABASE_URL;
  assert.equal((await createJbDevDailyReportReader(incomplete, { fetchUser })(request)).status, 'not_implemented');
  assert.throws(() => createJbDevDailyReportReader({ ...env, JB_REPORT_SUPABASE_URL: 'https://other.supabase.co' }), /Auth project/);
  for (const dsn of [
    env.JB_REPORT_DATABASE_URL.replace(jbDevProject, 'other'),
    env.JB_REPORT_DATABASE_URL.replace('verify-full', 'disable'),
    env.JB_REPORT_DATABASE_URL + '&host=other',
    env.JB_REPORT_DATABASE_URL.replace('synthetic_reader', 'postgres'),
  ]) assert.throws(() => createJbDevDailyReportReader({ ...env, JB_REPORT_DATABASE_URL: dsn }), /database DSN/);
});

function mockReader({ role = 'owner', active = true, duplicate = false, countDelta = 0, filtered = false, roleBlocked = false,
  pgError, tasks = source.tasks.pages[0].rows, history = source.history.pages[0].rows, brokenSchema = false } = {}) {
  const calls = [];
  const schemaRows = Object.entries(source.schema).flatMap(([table_name, columns]) =>
    Object.entries(columns).map(([column_name, type]) => ({
      table_name, column_name, udt_name: type.slice(0, -1), is_nullable: type.endsWith('?') ? 'YES' : 'NO',
    })));
  const client = {
    async query(sql, params = []) {
      calls.push({ sql, params });
      let rows = [];
      if (sql.includes('pg_current_snapshot')) {
        assert.match(sql, /r\.rolbypassrls/);
        assert.match(sql, /pg_has_role\(session_user/);
        assert.match(sql, /has_any_column_privilege/);
        assert.ok(params[0].includes('supabase_read_only_user'));
        rows = [{ snapshot_id: '1:10:2,3', as_of: source.asOf, filtered, role_blocked: roleBlocked }];
      }
      else if (sql.includes('WHERE auth_user_id')) {
        assert.deepEqual(params, [authId]);
        const employee = { id: id(91), auth_user_id: authId, app_role: role, active };
        rows = duplicate ? [employee, employee] : [employee];
      } else if (sql.includes('SELECT id FROM public.jb_employees')) {
        assert.ok(staff.some(person => person.id === params[0]));
        rows = [{ id: params[0] }];
      } else if (sql.includes('information_schema.columns')) {
        rows = brokenSchema ? schemaRows.filter(row => row.column_name !== 'changed_at') : schemaRows;
      } else if (sql.includes('pg_get_expr')) {
        rows = [{ expression: "(status = ANY (ARRAY['planned'::text, 'in_progress'::text, 'hold'::text, 'completed'::text]))" }];
      } else if (sql.includes('count(*)')) {
        assert.deepEqual(params, [source.cutoff]);
        rows = [{ task_count: String(tasks.length), history_count: String(history.length + countDelta) }];
      } else if (sql.includes('ORDER BY t.id')) {
        const [cutoff, after, limit] = params;
        assert.equal(cutoff, source.cutoff);
        rows = tasks.filter(row => after === null || row.id > after).slice(0, limit);
      } else if (sql.includes('ORDER BY h.changed_at, h.id')) {
        if (pgError) throw pgError;
        const [cutoff, changedAt, eventId, limit] = params;
        assert.equal(cutoff, source.cutoff);
        rows = history.filter(row => changedAt === null || row.changed_at + '/' + row.id > changedAt + '/' + eventId).slice(0, limit);
      } else {
        assert.match(sql, /^(BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY|SET LOCAL statement_timeout = '15s'|COMMIT|ROLLBACK)$/);
      }
      return { rows };
    },
    release(discard) { calls.push({ sql: 'release', params: [discard] }); },
  };
  class MockPool {
    async connect() { calls.push({ sql: 'connect' }); return client; }
  }
  const reader = createJbDevDailyReportReader(env, {
    Pool: MockPool, pageSize: 2, fetchUser: async () => Response.json({ id: authId }),
  });
  return { calls, reader };
}

test('one connection and one read-only repeatable snapshot contain both counts and all pages', async () => {
  const { reader, calls } = mockReader();
  const result = await reader(request);
  assert.equal(result.status, 'ready');
  assert.deepEqual(result.report.tasks, []);
  assert.ok(result.report.unverifiedAssignment.length);
  assert.equal(result.report.start, '2026-11-21T15:00:00.000000Z');
  assert.deepEqual(calls.slice(0, 3).map(call => call.sql),
    ['connect', 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY', "SET LOCAL statement_timeout = '15s'"]);
  assert.equal(calls.filter(call => call.sql.includes('count(*)')).length, 1);
  assert.equal(calls.filter(call => call.sql.includes('ORDER BY t.id')).length, 4);
  assert.equal(calls.filter(call => call.sql.includes('ORDER BY h.changed_at, h.id')).length, 5);
  assert.deepEqual(calls.slice(-2).map(call => call.sql), ['COMMIT', 'release']);
  assert.ok(calls.every(({ sql }) => !/\b(INSERT|UPDATE|DELETE|TRUNCATE)\b/i.test(sql.replace(/'[^']*'/g, ''))));
  assert.ok(calls.filter(call => call.sql.includes('ORDER BY')).every(call => !call.sql.includes('t.assignee_id =')));
});

test('roles, inactivity, duplicate links and filtered scope stop before report reads', async () => {
  for (const options of [
    { role: 'manager' }, { role: 'staff' }, { active: false }, { duplicate: true }, { filtered: true },
  ]) {
    const { reader, calls } = mockReader(options);
    assert.equal((await reader({ ...request, role: 'owner' })).status, 'forbidden');
    assert.ok(!calls.some(call => call.sql.includes('count(*)')));
    assert.deepEqual(calls.slice(-2).map(call => call.sql), ['ROLLBACK', 'release']);
  }
});

test('SQL errors roll back, release, and preserve permission denial', async () => {
  for (const [code, status] of [['42501', 'forbidden'], ['XX000', 'error']]) {
    const { reader, calls } = mockReader({ pgError: Object.assign(new Error('synthetic DB detail'), { code }) });
    assert.deepEqual(await reader(request), { status, report: null });
    assert.deepEqual(calls.slice(-2).map(call => call.sql), ['ROLLBACK', 'release']);
  }
});

test('zero rows, missing rows and drift are distinct', async () => {
  for (const [options, status] of [
    [{ tasks: [], history: [] }, 'empty'], [{ countDelta: 1 }, 'incomplete'],
    [{ brokenSchema: true }, 'incompatible'],
  ]) {
    const { reader, calls } = mockReader(options);
    assert.equal((await reader(request)).status, status);
    assert.equal(calls.at(-2).sql, status === 'empty' ? 'COMMIT' : 'ROLLBACK');
  }
});

test('microsecond cursor preserves tied timestamps across pages without inventing event order', async () => {
  const task = source.tasks.pages[0].rows[0];
  const tied = '2026-11-22T00:00:00.123456Z';
  const event = { task_id: task.id, changed_by: null, changed_at: tied };
  const history = [
    { ...event, id: id(700), previous_status: 'planned', new_status: 'in_progress' },
    { ...event, id: id(701), previous_status: 'in_progress', new_status: 'hold' },
    { ...event, id: id(702), previous_status: 'hold', new_status: 'completed' },
  ];
  const { reader, calls } = mockReader({ tasks: [task], history });
  const result = await reader({ ...request, employeeId: task.assignee_id });
  assert.equal(result.status, 'ready');
  const [row] = result.report.unverifiedAssignment;
  assert.ok(row.issues.includes('conflicting_event_time'));
  const pages = calls.filter(call => call.sql.includes('ORDER BY h.changed_at, h.id'));
  assert.deepEqual(pages[1].params, [source.cutoff, tied, id(701), 2]);
});

test('known broad login names are rejected for direct and pooler configurations', () => {
  for (const role of ['supabase_read_only_user', 'supabase_admin', 'postgres', 'service_role']) {
    const direct = env.JB_REPORT_DATABASE_URL.replace('synthetic_reader', role);
    const pooler = direct.replace(role + '@db.' + jbDevProject + '.supabase.co',
      role + '.' + jbDevProject + '@synthetic.pooler.supabase.com');
    for (const dsn of [direct, pooler]) {
      assert.throws(() => createJbDevDailyReportReader({ ...env, JB_REPORT_DATABASE_URL: dsn }), /database DSN/);
    }
  }
});

test('overprivileged or unverified runtime role is rejected before any employee or report query', async () => {
  for (const roleBlocked of [true, null]) {
    const { reader, calls } = mockReader({ roleBlocked });
    assert.deepEqual(await reader(request), { status: 'forbidden', report: null });
    assert.ok(!calls.some(call => call.sql.includes('WHERE auth_user_id') || call.sql.includes('count(*)')));
    assert.deepEqual(calls.slice(-2).map(call => call.sql), ['ROLLBACK', 'release']);
  }
});
