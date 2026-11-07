-- JB 업무관리 V1.3 / 관리자 본인 휴무 자동 승인·수정·취소 보완
-- 적용 환경: Supabase 운영 프로젝트 업무관리앱 (2026-11-07 설치 완료)
-- 기존 휴무 기록은 삭제하지 않으며, 승인 취소 이력을 감사 테이블에 보존합니다.
BEGIN;
ALTER TABLE public.jb_leave_requests
 DROP CONSTRAINT jb_leave_requests_approval_status_check;
ALTER TABLE public.jb_leave_requests
 ADD CONSTRAINT jb_leave_requests_approval_status_check
 CHECK (approval_status = ANY (ARRAY['pending'::text,'approved'::text,'rejected'::text,'cancelled'::text]));

CREATE OR REPLACE FUNCTION public.jb_manager_update_own_leave_v13(
 p_request_id uuid,p_start_date date,p_end_date date,p_reason text,p_leave_category text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
 v_employee_id uuid;
 v_old public.jb_leave_requests%ROWTYPE;
 v_new public.jb_leave_requests%ROWTYPE;
BEGIN
 v_employee_id := public.jb_manager_self_leave_user_v13();
 IF p_request_id IS NULL OR p_start_date IS NULL OR p_end_date IS NULL OR p_end_date<p_start_date
    OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 1 AND 500
    OR p_leave_category NOT IN ('general','annual','half_am','half_pm')
    OR p_leave_category IS NULL
 THEN RAISE EXCEPTION '수정 내용이 올바르지 않습니다.'; END IF;
 IF p_leave_category IN ('half_am','half_pm') AND p_start_date<>p_end_date
 THEN RAISE EXCEPTION '반차는 하루만 지정할 수 있습니다.'; END IF;
 SELECT * INTO v_old FROM public.jb_leave_requests
 WHERE id=p_request_id AND employee_id=v_employee_id AND request_type='leave'
   AND approval_status='approved' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '수정 가능한 본인 승인 휴무가 없습니다.'; END IF;
 IF EXISTS(SELECT 1 FROM public.jb_leave_change_requests WHERE request_id=p_request_id AND status='pending')
 THEN RAISE EXCEPTION '기존 변경 승인 요청이 처리되기 전에는 직접 수정할 수 없습니다.'; END IF;
 UPDATE public.jb_leave_requests
 SET start_date=p_start_date,end_date=p_end_date,reason=btrim(p_reason),
 leave_category=p_leave_category,reviewed_at=now()
 WHERE id=v_old.id RETURNING * INTO v_new;
 INSERT INTO public.jb_leave_request_audit
 (request_id,employee_id,action,before_row,after_row,actor_user_id)
 VALUES(v_old.id,v_old.employee_id,'edit',to_jsonb(v_old),to_jsonb(v_new),auth.uid());
 RETURN true;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.jb_manager_delete_own_leave_v13(p_request_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
 v_employee_id uuid;
 v_old public.jb_leave_requests%ROWTYPE;
 v_new public.jb_leave_requests%ROWTYPE;
BEGIN
 v_employee_id := public.jb_manager_self_leave_user_v13();
 SELECT * INTO v_old FROM public.jb_leave_requests
 WHERE id=p_request_id AND employee_id=v_employee_id AND request_type='leave'
   AND approval_status='approved' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '삭제 가능한 본인 승인 휴무가 없습니다.'; END IF;
 IF EXISTS(SELECT 1 FROM public.jb_leave_change_requests WHERE request_id=p_request_id AND status='pending')
 THEN RAISE EXCEPTION '기존 변경 승인 요청이 처리되기 전에는 직접 삭제할 수 없습니다.'; END IF;
 UPDATE public.jb_leave_requests SET approval_status='cancelled'
 WHERE id=v_old.id RETURNING * INTO v_new;
 INSERT INTO public.jb_leave_request_audit
 (request_id,employee_id,action,before_row,after_row,actor_user_id)
 VALUES(v_old.id,v_old.employee_id,'cancel',to_jsonb(v_old),to_jsonb(v_new),auth.uid());
 RETURN true;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.jb_manager_self_leave_user_v13() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.jb_manager_create_own_leave_v13(date,date,text,text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.jb_manager_update_own_leave_v13(uuid,date,date,text,text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.jb_manager_delete_own_leave_v13(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_manager_self_leave_user_v13() TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_manager_create_own_leave_v13(date,date,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_manager_update_own_leave_v13(uuid,date,date,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_manager_delete_own_leave_v13(uuid) TO authenticated;
COMMIT;
