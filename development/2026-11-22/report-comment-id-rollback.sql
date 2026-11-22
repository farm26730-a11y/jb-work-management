-- Roll back the frontend first. Existing reports, comments and photos are retained.
BEGIN;
DROP FUNCTION public.jb_submit_task_report_comment_id_v13(uuid,text,boolean);
NOTIFY pgrst, 'reload schema';
COMMIT;
