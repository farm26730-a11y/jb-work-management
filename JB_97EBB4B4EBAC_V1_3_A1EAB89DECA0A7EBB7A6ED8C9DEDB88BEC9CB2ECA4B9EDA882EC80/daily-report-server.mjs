import { adaptDailyTaskSource, adaptIntegratedDailyTaskSource } from './daily-task-adapter.mjs';
import { summarizeDailyTaskRows } from './daily-task-time.mjs';

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const isUuid = value => typeof value === 'string' && uuid.test(value);
const unavailable = status => ({ status, report: null });

/**
 * Server-only orchestration. verifyAccessToken is the trusted auth provider port.
 * withReadOnlySnapshot must run its callback within one actual read-only,
 * consistent transaction. No production implementation is supplied here.
 */
export function createDailyReportReader({ verifyAccessToken, withReadOnlySnapshot, integrated = false } = {}) {
  return async function readDailyReport({ session, employeeId, date, cutoffTime } = {}) {
    if (typeof verifyAccessToken !== 'function' || typeof withReadOnlySnapshot !== 'function') {
      return unavailable('not_implemented');
    }
    if (typeof session !== 'string' || !session.trim()) return unavailable('unauthenticated');

    try {
      const identity = await verifyAccessToken(session);
      if (!isUuid(identity?.userId)) return unavailable('unauthenticated');
      const authUserId = identity.userId;

      if (!integrated && !isUuid(employeeId)) return unavailable('invalid_request');
      let window;
      try {
        const { start, cutoff } = summarizeDailyTaskRows({ date, cutoffTime, tasks: [], history: [] });
        window = Object.freeze({ start, cutoff });
      } catch (error) {
        if (error instanceof RangeError) return unavailable('invalid_request');
        throw error;
      }

      return await withReadOnlySnapshot(async transaction => {
        const matches = await transaction.findEmployeesByAuthUserId(authUserId);
        if (!Array.isArray(matches)) return unavailable('error');
        const [caller] = matches;
        if (matches.length !== 1 || caller?.auth_user_id !== authUserId ||
            !isUuid(caller.id) || caller.active !== true || caller.app_role !== 'owner') {
          return unavailable('forbidden');
        }

        if (integrated) {
          const { source, assignmentLedger, presentation } = await transaction.readReportSource(window);
          return adaptIntegratedDailyTaskSource({ date, cutoffTime, source, assignmentLedger, presentation });
        }
        const target = await transaction.findEmployeeById(employeeId);
        if (target === null) return unavailable('not_found');
        if (target?.id !== employeeId) return unavailable('error');

        const { source, assignmentLedger } = await transaction.readReportSource(
          Object.freeze({ employeeId: target.id, ...window }),
        );
        return adaptDailyTaskSource({ date, cutoffTime, employeeId: target.id, source, assignmentLedger });
      });
    } catch {
      return unavailable('error');
    }
  };
}
