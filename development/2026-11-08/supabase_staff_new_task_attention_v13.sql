-- [설치용] JB 업무관리 V1.3 직원 홈: 새 업무 지시 확인 요청
-- 운영 배포 전에 SQL Editor에서 실행해야 함. 기존 업무/근태 데이터는 변경하지 않음.
-- 신규/재배정 업무만 기록: 기존 수백 건을 새 확인 요청으로 소급 표시하지 않음.
BEGIN;

CREATE TABLE IF NOT EXISTS public.jb_task_assignment_ack_v13 (
 task_id uuid PRIMARY KEY REFERENCES public.jb_tasks(id) ON DELETE CASCADE,
 employee_id uuid NOT NULL REFERENCES public.jb_employees(id),
 assigned_at timestamptz NOT NULL DEFAULT now(),
 acknowledged_at timestamptz
);

CREATE INDEX IF NOT EXISTS jb_task_assignment_ack_v13_staff_pending_idx
 ON public.jb_task_assignment_ack_v13(employee_id,assigned_at DESC)
 WHERE acknowledged_at IS NULL;

ALTER TABLE public.jb_task_assignment_ack_v13 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS jb_task_assignment_ack_v13_own_select ON public.jb_task_assignment_ack_v13;
CREATE POLICY jb_task_assignment_ack_v13_own_select
 ON public.jb_task_assignment_ack_v13
 FOR SELECT TO authenticated
 USING (
  employee_id IN (
   SELECT id FROM public.jb_employees
   WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE
  )
 );
REVOKE ALL ON TABLE public.jb_task_assignment_ack_v13 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.jb_task_assignment_ack_v13 TO authenticated;

-- 트리거는 SECURITY DEFINER이며 클라이언트는 직접 INSERT/UPDATE/DELETE 불가.
CREATE OR REPLACE FUNCTION public.jb_track_task_assignment_v13()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
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
 ELSIF TG_OP='UPDATE' THEN
  DELETE FROM public.jb_task_assignment_ack_v13 WHERE task_id=NEW.id;
 END IF;
 RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS jb_track_task_assignment_v13_trigger ON public.jb_tasks;
CREATE TRIGGER jb_track_task_assignment_v13_trigger
 AFTER INSERT OR UPDATE OF assignee_id ON public.jb_tasks
 FOR EACH ROW EXECUTE FUNCTION public.jb_track_task_assignment_v13();

-- 본인에게 실제로 배정된 미완료 신규 지시만 확인 가능. 중복 확인 불가.
CREATE OR REPLACE FUNCTION public.jb_acknowledge_assigned_task_v13(p_task_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
 v_me uuid;
 v_at timestamptz;
BEGIN
 SELECT id INTO v_me FROM public.jb_employees
  WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE AND app_role='staff';
 IF v_me IS NULL THEN
  RAISE EXCEPTION '활성 직원 계정만 업무 지시를 확인할 수 있습니다' USING ERRCODE='42501';
 END IF;
 UPDATE public.jb_task_assignment_ack_v13 a
 SET acknowledged_at=now()
 WHERE a.task_id=p_task_id AND a.employee_id=v_me AND a.acknowledged_at IS NULL
  AND EXISTS (
   SELECT 1 FROM public.jb_tasks t
   WHERE t.id=a.task_id AND t.assignee_id=v_me AND t.status <> 'completed'
  )
 RETURNING a.acknowledged_at INTO v_at;
 IF v_at IS NULL THEN
  RAISE EXCEPTION '확인 가능한 신규 업무 지시가 없습니다' USING ERRCODE='42501';
 END IF;
 RETURN v_at;
END;
$fn$;

REVOKE ALL ON FUNCTION public.jb_acknowledge_assigned_task_v13(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.jb_acknowledge_assigned_task_v13(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.jb_track_task_assignment_v13() FROM PUBLIC,anon,authenticated;
COMMIT;

-- [조회용 / 설치 검증] 아래 쿼리는 별도로 실행
-- SELECT count(*) FROM public.jb_task_assignment_ack_v13;
-- SELECT tgname,tgenabled FROM pg_trigger WHERE tgrelid='public.jb_tasks'::regclass AND tgname='jb_track_task_assignment_v13_trigger';
-- SELECT proname FROM pg_proc WHERE proname='jb_acknowledge_assigned_task_v13';
-- [주의] 실제 신규 업무 테스트는 관리자 계정으로 직원에게 새 업무 등록 후 수행.
-- [삭제/되돌리기용 / 별도 실행] DROP TRIGGER IF EXISTS jb_track_task_assignment_v13_trigger ON public.jb_tasks;
-- DROP FUNCTION IF EXISTS public.jb_track_task_assignment_v13();
-- DROP FUNCTION IF EXISTS public.jb_acknowledge_assigned_task_v13(uuid);
-- DROP TABLE IF EXISTS public.jb_task_assignment_ack_v13;
