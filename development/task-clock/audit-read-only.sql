-- Run with an authorized database reader that can see the full task/history tables.
-- This script reports aggregates and inspects definitions. It never invokes the RPC.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

SELECT p.oid::regprocedure AS signature, p.prosecdef AS security_definer,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'jb_set_task_status_exclusive';

SELECT t.tgrelid::regclass AS relation, t.tgname AS trigger_name, t.tgenabled,
       pg_get_triggerdef(t.oid) AS trigger_definition,
       pg_get_functiondef(t.tgfoid) AS function_definition
FROM pg_trigger AS t
WHERE NOT t.tgisinternal
  AND t.tgrelid IN ('public.jb_tasks'::regclass, 'public.jb_task_history'::regclass)
ORDER BY relation, trigger_name;

SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'public' AND tablename IN ('jb_tasks', 'jb_task_history');

WITH history AS (
  SELECT h.*, lag(new_status::text, 1, 'planned') OVER timeline AS expected_previous,
         lead(changed_at) OVER timeline AS next_at,
         row_number() OVER timeline AS step,
         count(*) OVER (PARTITION BY task_id, changed_at, previous_status, new_status) AS matching_rows
  FROM public.jb_task_history AS h
  WINDOW timeline AS (PARTITION BY task_id ORDER BY changed_at, id)
), per_task AS (
  SELECT t.id, t.status::text AS status, t.assignee_id, t.created_at,
         count(h.id) AS history_rows,
         (array_agg(h.new_status::text ORDER BY h.step DESC) FILTER (WHERE h.id IS NOT NULL))[1] AS last_status,
         count(*) FILTER (WHERE h.new_status::text = 'in_progress' AND h.changed_at IS NOT NULL) AS recorded_starts,
         bool_or(h.id IS NOT NULL AND (
           h.changed_at IS NULL OR h.changed_at < t.created_at OR h.changed_at > transaction_timestamp()
           OR h.new_status IS NULL OR h.new_status::text NOT IN ('planned','in_progress','hold','completed')
           OR (h.previous_status::text IS DISTINCT FROM h.expected_previous
               AND NOT (h.step = 1 AND h.previous_status IS NULL AND h.new_status::text = 'planned'))
         )) AS invalid_history,
         bool_or(h.matching_rows > 1) AS duplicate_history
  FROM public.jb_tasks AS t
  LEFT JOIN history AS h ON h.task_id = t.id
  GROUP BY t.id, t.status, t.assignee_id, t.created_at
), running_intervals AS (
  SELECT h.task_id, t.assignee_id, h.changed_at AS start_at,
         coalesce(h.next_at, transaction_timestamp()) AS end_at
  FROM history AS h
  JOIN public.jb_tasks AS t ON t.id = h.task_id
  WHERE h.new_status::text = 'in_progress' AND t.assignee_id IS NOT NULL
    AND (h.next_at IS NOT NULL OR t.status::text = 'in_progress')
)
SELECT count(*) AS tasks,
       (SELECT count(*) FROM history) AS history_rows,
       count(*) FILTER (WHERE status = 'in_progress') AS running_tasks,
       count(*) FILTER (WHERE status = 'in_progress' AND history_rows = 0) AS running_without_history,
       count(*) FILTER (WHERE status = 'in_progress' AND recorded_starts = 0) AS running_without_start_timestamp,
       count(*) FILTER (WHERE created_at IS NULL) AS missing_created_at,
       count(*) FILTER (WHERE history_rows > 0 AND last_status IS DISTINCT FROM status) AS latest_status_mismatch,
       count(*) FILTER (WHERE invalid_history) AS invalid_transition_or_timestamp,
       count(*) FILTER (WHERE created_at IS NULL OR invalid_history
         OR (history_rows = 0 AND status <> 'planned')
         OR (history_rows > 0 AND last_status IS DISTINCT FROM status)) AS uncomputable_tasks,
       count(*) FILTER (WHERE duplicate_history) AS tasks_with_exact_duplicate_transitions,
       (SELECT count(*) FROM history WHERE matching_rows > 1) AS rows_in_duplicate_transition_groups,
       (SELECT count(*) FROM (
          SELECT assignee_id FROM per_task WHERE status = 'in_progress' AND assignee_id IS NOT NULL
          GROUP BY assignee_id HAVING count(*) > 1
        ) AS concurrent) AS assignees_with_multiple_running_tasks,
       (SELECT count(*) FROM running_intervals AS a
        WHERE a.start_at < a.end_at AND EXISTS (
          SELECT 1 FROM running_intervals AS b
          WHERE b.assignee_id = a.assignee_id AND b.task_id <> a.task_id
            AND b.start_at < b.end_at AND b.start_at < a.end_at AND a.start_at < b.end_at
        )) AS potentially_overlapping_intervals_by_current_assignee
FROM per_task;

ROLLBACK;
