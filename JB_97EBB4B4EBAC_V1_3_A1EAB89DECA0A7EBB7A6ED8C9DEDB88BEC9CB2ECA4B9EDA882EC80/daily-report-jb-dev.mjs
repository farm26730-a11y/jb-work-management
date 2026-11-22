import { createDailyReportReader } from './daily-report-server.mjs';
import { createSupabaseTokenVerifier } from './daily-report-auth.mjs';
import { createPostgresSnapshot } from './daily-report-postgres.mjs';

export function createJbDevDailyReportReader(env = process.env, { fetchUser, Pool, pageSize } = {}) {
  const { JB_REPORT_SUPABASE_URL, JB_REPORT_SUPABASE_PUBLISHABLE_KEY, JB_REPORT_DATABASE_URL } = env;
  if (!JB_REPORT_SUPABASE_URL || !JB_REPORT_SUPABASE_PUBLISHABLE_KEY || !JB_REPORT_DATABASE_URL) {
    return createDailyReportReader();
  }
  return createDailyReportReader({
    verifyAccessToken: createSupabaseTokenVerifier({
      url: JB_REPORT_SUPABASE_URL, publishableKey: JB_REPORT_SUPABASE_PUBLISHABLE_KEY, fetchUser,
    }),
    withReadOnlySnapshot: createPostgresSnapshot({ connectionString: JB_REPORT_DATABASE_URL, Pool, pageSize }),
  });
}
