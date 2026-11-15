-- JB-DEV only; do not apply to operating bnonnvgtbukztfhaxgrr without explicit release.
-- Preserve existing task-photo privileges. Grant comment images to their own active authors only.
CREATE OR REPLACE FUNCTION public.jb_comment_photo_can_upload_v13(p_storage_path text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
 SELECT
   COALESCE(
     p_storage_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/comments/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(jpg|jpeg|png|webp)$',
     false
   )
   AND EXISTS (
     SELECT 1
       FROM public.jb_employees AS e
       JOIN public.jb_task_comments AS c ON c.author_id=e.id
       JOIN public.jb_tasks AS t ON t.id=c.task_id
      WHERE e.auth_user_id = (SELECT auth.uid())
        AND e.active IS TRUE
        AND c.id::text=split_part(p_storage_path,'/',3)
        AND t.id::text=split_part(p_storage_path,'/',1)
   );
$function$;

REVOKE ALL ON FUNCTION public.jb_comment_photo_can_upload_v13(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jb_comment_photo_can_upload_v13(text) TO authenticated;

DROP POLICY IF EXISTS jb_comment_photo_insert_v13 ON storage.objects;
CREATE POLICY jb_comment_photo_insert_v13
 ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
 WITH CHECK (
   bucket_id='jb-task-images'
   AND public.jb_comment_photo_can_upload_v13(name)
 );

DROP POLICY IF EXISTS jb_comment_image_record_insert_v13 ON public.jb_task_images;
CREATE POLICY jb_comment_image_record_insert_v13
 ON public.jb_task_images AS PERMISSIVE FOR INSERT TO authenticated
 WITH CHECK (
   comment_id IS NOT NULL
   AND comment_id::text=split_part(storage_path,'/',3)
   AND uploaded_by=(
      SELECT e.id FROM public.jb_employees AS e
      WHERE e.auth_user_id=(SELECT auth.uid()) AND e.active IS TRUE
      LIMIT 1
   )
   AND public.jb_comment_photo_can_upload_v13(storage_path)
   AND task_id::text=split_part(storage_path,'/',1)
 );

-- Even if the task-photo policy permits an owner/manager to write an image record,
-- they may not attach a new image to another person's existing comment.
DROP POLICY IF EXISTS jb_comment_image_record_author_guard_v13 ON public.jb_task_images;
CREATE POLICY jb_comment_image_record_author_guard_v13
 ON public.jb_task_images AS RESTRICTIVE FOR INSERT TO authenticated
 WITH CHECK (
   comment_id IS NULL OR (
     uploaded_by=(
        SELECT e.id FROM public.jb_employees AS e
        WHERE e.auth_user_id=(SELECT auth.uid()) AND e.active IS TRUE
        LIMIT 1
     )
     AND comment_id::text=split_part(storage_path,'/',3)
     AND public.jb_comment_photo_can_upload_v13(storage_path)
     AND task_id::text=split_part(storage_path,'/',1)
   )
 );
