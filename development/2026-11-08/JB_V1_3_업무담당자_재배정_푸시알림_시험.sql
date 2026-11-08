-- [시험용 설치 초안] JB 업무관리 V1.3 기존 업무 담당자 재배정 푸시 누락 보완
-- 운영 적용 금지. 기존 업무지시 신규 생성 푸시와 중복되지 않도록 UPDATE일 때만 추가.
-- 부서별 권한 및 수신자 제한 규칙을 변경하지 않음.
-- 실제 운영 DB에서 읽어온 함수 정의를 기반으로 수신 알림 로직만 추가.
-- Supabase 운영 DB에는 실행하지 않았음.

CREATE OR REPLACE FUNCTION public.jb_track_task_assignment_v13()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_assignee_role text;
 v_creator_role text;
BEGIN
 IF TG_OP='UPDATE' AND NEW.assignee_id IS NOT DISTINCT FROM OLD.assignee_id THEN
  RETURN NEW;
 END IF;
 SELECT app_role INTO v_assignee_role
 FROM public.jb_employees WHERE id=NEW.assignee_id AND active IS TRUE;
 SELECT app_role INTO v_creator_role
 FROM public.jb_employees WHERE id=NEW.created_by AND active IS TRUE;
 IF NEW.assignee_id IS NOT NULL
    AND NEW.assignee_id IS DISTINCT FROM NEW.created_by
    AND v_assignee_role='staff'
    AND v_creator_role IN ('owner','manager')
    AND NEW.status <> 'completed' THEN
  INSERT INTO public.jb_task_assignment_ack_v13(task_id,employee_id,assigned_at,acknowledged_at)
   VALUES(NEW.id,NEW.assignee_id,now(),NULL)
  ON CONFLICT (task_id) DO UPDATE
   SET employee_id=EXCLUDED.employee_id,
       assigned_at=EXCLUDED.assigned_at,
       acknowledged_at=NULL;
  -- 최초 INSERT는 기존 jb_push_task_insert_v34 트리거가 푸시를 처리합니다.
  -- 담당자를 변경한 UPDATE에서는 신규 담당자의 푸시가 빠지지 않도록 보완합니다.
  IF TG_OP='UPDATE' THEN
   PERFORM public.jb_queue_push_event(
    'task:reassign:' || NEW.id::text || ':' ||
      (pg_catalog.extract(epoch from pg_catalog.clock_timestamp()) * 1000000)::bigint::text,
    NEW.assignee_id,
    'task'
   );
  END IF;
 ELSIF TG_OP='UPDATE' THEN
  DELETE FROM public.jb_task_assignment_ack_v13 WHERE task_id=NEW.id;
 END IF;
 RETURN NEW;
END;
$function$;

-- [조회용] 운영/시험 DB 함수 정의 검사 (설치 후 별도 실행)
-- SELECT pg_get_functiondef('public.jb_track_task_assignment_v13()'::regprocedure);
