import { jbDevProject } from './daily-report-auth.mjs';
import { isDailyTaskSourceSchemaCompatible } from './daily-task-adapter.mjs';

const blockedRoles = [
  'postgres', 'supabase_admin', 'supabase_read_only_user', 'service_role',
  'pg_read_all_data', 'pg_write_all_data',
];
const fromTasks = 'FROM public.jb_tasks t WHERE t.created_at <= $1::timestamptz';
const fromHistory = `FROM public.jb_task_history h JOIN public.jb_tasks t ON t.id = h.task_id
  WHERE h.changed_at <= $1::timestamptz AND t.created_at <= $1::timestamptz`;
const utc = column => `to_char(${column} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;
const catalog = `SELECT table_name, column_name, udt_name, is_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name IN ('jb_employees', 'jb_tasks', 'jb_task_history')`;
const checks = `SELECT pg_catalog.pg_get_expr(c.conbin, c.conrelid) AS expression
  FROM pg_catalog.pg_constraint c
  JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attname = 'status'
  WHERE c.conrelid = pg_catalog.to_regclass('public.jb_tasks')
    AND c.contype = 'c' AND c.convalidated AND a.attnum = ANY(c.conkey)`;

// A dedicated SELECT policy can prove full visibility without bypassing RLS.
const visibilityQuery = `WITH required(name, columns) AS (
  VALUES
    ('public.jb_employees', ARRAY['id', 'auth_user_id', 'active', 'app_role']),
    ('public.jb_tasks', ARRAY['id', 'assignee_id', 'created_at', 'status']),
    ('public.jb_task_history', ARRAY['id', 'task_id', 'changed_by', 'previous_status', 'new_status', 'changed_at'])
),
reader AS (
  SELECT oid FROM pg_catalog.pg_roles WHERE rolname = current_user
)
SELECT coalesce(bool_and(
  c.relkind = 'r'
  AND has_schema_privilege('public', 'USAGE')
  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhparent = c.oid)
  AND NOT EXISTS (
    SELECT 1 FROM unnest(required.columns) AS cols(name)
    LEFT JOIN pg_catalog.pg_attribute a
      ON a.attrelid = c.oid AND a.attname = cols.name AND a.attnum > 0 AND NOT a.attisdropped
    WHERE a.attnum IS NULL OR has_column_privilege(c.oid, a.attnum, 'SELECT') IS NOT TRUE
  )
  AND (
    NOT c.relrowsecurity
    OR (
      EXISTS (
        SELECT 1 FROM pg_catalog.pg_policy p
        WHERE p.polrelid = c.oid AND p.polname = 'jb_ai_report_full_read'
          AND p.polpermissive AND p.polcmd = 'r' AND p.polroles = ARRAY[reader.oid]
          AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) = 'true'
      )
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_policy p
        CROSS JOIN LATERAL unnest(p.polroles) AS roles(oid)
        WHERE p.polrelid = c.oid AND NOT p.polpermissive AND p.polcmd IN ('r', '*')
          AND CASE WHEN roles.oid = 0 THEN true ELSE pg_catalog.pg_has_role(roles.oid, 'USAGE') END
      )
    )
  )
  IS TRUE
), false) AS complete
FROM required CROSS JOIN reader
LEFT JOIN pg_catalog.pg_class c ON c.oid = pg_catalog.to_regclass(required.name)`;

function statusValues(rows) {
  // Accept the deployed text ANY(ARRAY[...]) constraint; other shapes need contract review.
  const expression = rows.length === 1 ? rows[0].expression : '';
  const match = /^\(status = ANY \(ARRAY\[('(?:[a-z_]+)'::text(?:,\s*'[a-z_]+'::text)*)\]\)\)$/.exec(expression);
  return match ? [...match[1].matchAll(/'([a-z_]+)'/g)].map(value => value[1]) : [];
}

function connectionForDev(connectionString) {
  let url;
  try {
    url = new URL(connectionString);
  } catch {
    throw new Error('Invalid report database configuration');
  }
  const username = decodeURIComponent(url.username);
  const direct = url.hostname === 'db.' + jbDevProject + '.supabase.co';
  const pooler = /^[a-z0-9-]+\.pooler\.supabase\.com$/.test(url.hostname) &&
    username.endsWith('.' + jbDevProject);
  // Disallow DSN option overrides for host, user, TLS and startup parameters.
  if (url.search !== '?sslmode=verify-full') throw new Error('Report database TLS configuration requires sslmode=verify-full');
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || (!direct && !pooler) ||
      !username || blockedRoles.includes(username.split('.')[0]) || url.pathname !== '/postgres' ||
      url.hash) {
    throw new Error('Expected an approved JB-DEV database DSN with TLS verification');
  }
  return url.href;
}

async function pages(client, { sql, count, cutoff, snapshotId, pageSize, cursorOf, cursorBindings }) {
  if (!Number.isSafeInteger(count) || count < 0) throw new Error('Invalid report row count');
  const result = [];
  let after = null;
  let received = 0;
  while (true) {
    const { rows } = await client.query(sql, [cutoff, ...cursorBindings(after), pageSize]);
    received += rows.length;
    const done = rows.length < pageSize;
    result.push({ status: 'ok', snapshotId, after, done, rows });
    if (done || received > count) return { count, pages: result };
    const next = cursorOf(rows.at(-1));
    if (after !== null && next <= after) return { count, pages: result };
    after = next;
  }
}

const taskPage = `SELECT t.id, t.assignee_id, t.status, ${utc('t.created_at')} AS created_at
  ${fromTasks}
  AND ($2::uuid IS NULL OR t.id > $2::uuid)
  ORDER BY t.id LIMIT $3::int`;
const historyPage = `SELECT h.id, h.task_id, h.changed_by, h.previous_status, h.new_status,
    ${utc('h.changed_at')} AS changed_at
  ${fromHistory}
  AND ($2::timestamptz IS NULL OR (h.changed_at, h.id) > ($2::timestamptz, $3::uuid))
  ORDER BY h.changed_at, h.id LIMIT $4::int`;

async function readSource(client, { cutoff }, { snapshot_id: snapshotId, as_of: asOf }, pageSize) {
  const schema = Object.create(null);
  for (const row of (await client.query(catalog)).rows) {
    schema[row.table_name] ??= Object.create(null);
    schema[row.table_name][row.column_name] = row.udt_name + (row.is_nullable === 'YES' ? '?' : '!');
  }
  const taskStatuses = statusValues((await client.query(checks)).rows);
  const source = {
    status: 'ok', authorization: 'verified', schema, taskStatuses, snapshotId, asOf, cutoff,
    contract: 'jb-task-source-v1', scope: 'all_tasks_created_through_cutoff_with_history',
  };
  if (!isDailyTaskSourceSchemaCompatible(schema, taskStatuses) || cutoff > asOf) return { source };

  const { rows: [counts] } = await client.query(`SELECT
    (SELECT count(*) ${fromTasks}) AS task_count,
    (SELECT count(*) ${fromHistory}) AS history_count`, [cutoff]);
  source.tasks = await pages(client, {
    sql: taskPage, count: Number(counts.task_count), cutoff, snapshotId, pageSize, cursorOf: row => row.id,
    cursorBindings: after => [after],
  });
  source.history = await pages(client, {
    sql: historyPage, count: Number(counts.history_count), cutoff, snapshotId, pageSize,
    cursorOf: row => row.changed_at + '/' + row.id,
    cursorBindings: after => after === null ? [null, null] : after.split('/'),
  });
  return { source };
}

export function createPostgresSnapshot({ connectionString, Pool, pageSize = 500 } = {}) {
  if (!connectionString) return undefined;
  const dsn = connectionForDev(connectionString);
  if (!Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > 1000) throw new RangeError('Invalid report page size');
  let pool;
  return async work => {
    if (!pool) {
      pool ??= Promise.resolve(Pool ?? import('pg').then(module => module.Pool))
        .then(Driver => new Driver({ connectionString: dsn, connectionTimeoutMillis: 5000 }));
    }
    let client;
    try {
      client = await (await pool).connect();
    } catch (error) {
      if (['28000', '28P01'].includes(error?.code)) return { status: 'database_auth_error', report: null };
      if (['CERT_HAS_EXPIRED', 'CERT_NOT_YET_VALID', 'ERR_TLS_CERT_ALTNAME_INVALID',
        'SELF_SIGNED_CERT_IN_CHAIN', 'DEPTH_ZERO_SELF_SIGNED_CERT',
        'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY'].includes(error?.code)) {
        return { status: 'database_tls_error', report: null };
      }
      throw new Error('Report database connection failed');
    }
    let discard = false;
    try {
      await client.query('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
      await client.query("SET LOCAL statement_timeout = '15s'");
      const { rows: [snapshot] } = await client.query(`SELECT
        pg_catalog.pg_current_snapshot()::text AS snapshot_id,
        ${utc('transaction_timestamp()')} AS as_of,
        (
          EXISTS (
            SELECT 1 FROM pg_catalog.pg_roles r
            WHERE (r.rolname::text = ANY($1::text[]) OR r.rolsuper OR r.rolbypassrls
              OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication)
              AND (pg_catalog.pg_has_role(current_user, r.oid, 'MEMBER')
                OR pg_catalog.pg_has_role(session_user, r.oid, 'MEMBER'))
          )
          OR pg_catalog.has_schema_privilege('public', 'CREATE')
          OR EXISTS (
            SELECT 1
            FROM (VALUES ('public.jb_employees'), ('public.jb_tasks'), ('public.jb_task_history')) AS t(name)
            WHERE pg_catalog.has_table_privilege(pg_catalog.to_regclass(t.name),
              'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
              OR pg_catalog.has_any_column_privilege(pg_catalog.to_regclass(t.name),
                'INSERT, UPDATE, REFERENCES')
          )
        ) AS role_blocked`, [blockedRoles]);
      if (snapshot?.role_blocked !== false) {
        await client.query('ROLLBACK');
        return { status: 'forbidden', report: null };
      }
      const { rows: [visibility] } = await client.query(visibilityQuery);
      if (visibility?.complete !== true) {
        await client.query('ROLLBACK');
        return { status: 'forbidden', report: null };
      }
      const result = await work({
        findEmployeesByAuthUserId: async id => (await client.query(`SELECT id, auth_user_id, active, app_role
          FROM public.jb_employees WHERE auth_user_id = $1::uuid LIMIT 2`, [id])).rows,
        findEmployeeById: async id => (await client.query(
          'SELECT id FROM public.jb_employees WHERE id = $1::uuid', [id],
        )).rows[0] ?? null,
        readReportSource: window => readSource(client, window, snapshot, pageSize),
      });
      await client.query(['ready', 'empty'].includes(result?.status) ? 'COMMIT' : 'ROLLBACK');
      return result;
    } catch (error) {
      try {
        await client.query('ROLLBACK');
      } catch {
        discard = true;
      }
      if (error?.code === '42501') return { status: 'forbidden', report: null };
      if (['42P01', '42703', '42804', '42883'].includes(error?.code)) {
        return { status: 'incompatible', report: null };
      }
      throw new Error('Report snapshot failed');
    } finally {
      client.release(discard);
    }
  };
}
