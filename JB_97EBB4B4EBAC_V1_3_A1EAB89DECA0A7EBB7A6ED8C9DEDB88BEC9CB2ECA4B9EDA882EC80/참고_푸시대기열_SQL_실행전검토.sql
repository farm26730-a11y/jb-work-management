-- JB 업무관리 V6.6.8.6.3.34 서버 알림 대기열
-- 설치 후에도 HTTPS/PWA/VAPID/Edge Function/스케줄러 없이는 휴대폰 알림 발송 안 됨.
-- 기존 업무·휴무·공지·알림 읽음 레코드 변경 없음.
BEGIN;
CREATE TABLE IF NOT EXISTS public.jb_push_outbox (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 event_key text NOT NULL,
 employee_id uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
 event_type text NOT NULL CHECK(event_type IN ('task','leave','report','announcement','comment')),
 created_at timestamptz NOT NULL DEFAULT now(),
 sent_at timestamptz,
 attempts integer NOT NULL DEFAULT 0,
 last_error text,
 UNIQUE(event_key, employee_id)
);
CREATE INDEX IF NOT EXISTS jb_push_outbox_pending_idx ON public.jb_push_outbox(created_at) WHERE sent_at IS NULL;
ALTER TABLE public.jb_push_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.jb_push_outbox FROM PUBLIC, anon, authenticated;
-- service_role (backend) only, ordinary authenticated clients cannot forge notifications.

CREATE OR REPLACE FUNCTION public.jb_queue_push_event(
 p_key text, p_target uuid, p_type text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF p_target IS NULL OR p_key IS NULL OR length(p_key)>290 THEN RETURN; END IF;
 IF p_type NOT IN ('task','leave','report','announcement','comment') THEN RETURN; END IF;
 INSERT INTO public.jb_push_outbox(event_key,employee_id,event_type)
 SELECT p_key,e.id,p_type FROM public.jb_employees e WHERE e.id=p_target AND e.active IS TRUE
 ON CONFLICT(event_key,employee_id) DO NOTHING;
END;
$fn$;
REVOKE ALL ON FUNCTION public.jb_queue_push_event(text,uuid,text) FROM PUBLIC, anon, authenticated;

-- 업무가 실제 DB에 등록되면 담당자에게 1회 발송 대기
CREATE OR REPLACE FUNCTION public.jb_push_task_insert_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF NEW.assignee_id IS DISTINCT FROM NEW.created_by THEN
  PERFORM public.jb_queue_push_event('task:'||NEW.id::text,NEW.assignee_id,'task');
 END IF;
 RETURN NEW;
END;$fn$;
DROP TRIGGER IF EXISTS jb_push_task_insert_v34 ON public.jb_tasks;
CREATE TRIGGER jb_push_task_insert_v34 AFTER INSERT ON public.jb_tasks
FOR EACH ROW EXECUTE FUNCTION public.jb_push_task_insert_trigger();

-- 휴무/연장근무 신청: 일반 직원 -> 활성 관리자, 관리자 -> 대표
CREATE OR REPLACE FUNCTION public.jb_push_leave_event_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE v_role text; v_target record;
BEGIN
 SELECT app_role INTO v_role FROM public.jb_employees WHERE id=NEW.employee_id;
 IF TG_OP='INSERT' AND NEW.approval_status='pending' THEN
  FOR v_target IN SELECT id FROM public.jb_employees
    WHERE active IS TRUE AND ((v_role='staff' AND app_role='manager') OR (v_role='manager' AND app_role='owner'))
  LOOP PERFORM public.jb_queue_push_event('leave:new:'||NEW.id::text,v_target.id,'leave'); END LOOP;
 ELSIF TG_OP='UPDATE' AND OLD.approval_status IS DISTINCT FROM NEW.approval_status
     AND NEW.approval_status IN ('approved','rejected') THEN
  PERFORM public.jb_queue_push_event('leave:decision:'||NEW.id::text||':'||NEW.approval_status,NEW.employee_id,'leave');
 END IF;
 RETURN NEW;
END;$fn$;
DROP TRIGGER IF EXISTS jb_push_leave_events_v34 ON public.jb_leave_requests;
CREATE TRIGGER jb_push_leave_events_v34 AFTER INSERT OR UPDATE OF approval_status ON public.jb_leave_requests
FOR EACH ROW EXECUTE FUNCTION public.jb_push_leave_event_trigger();

-- 승인 휴무 변경/취소 요청과 결과. 대표에게 일반 직원 요청은 보내지 않음.
CREATE OR REPLACE FUNCTION public.jb_push_leave_change_event_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE v_role text; v_target record;
BEGIN
 SELECT app_role INTO v_role FROM public.jb_employees WHERE id=NEW.employee_id;
 IF TG_OP='INSERT' AND NEW.status='pending' THEN
  FOR v_target IN SELECT id FROM public.jb_employees
   WHERE active IS TRUE AND ((v_role='staff' AND app_role='manager') OR (v_role='manager' AND app_role='owner'))
  LOOP PERFORM public.jb_queue_push_event('leavechange:new:'||NEW.id::text,v_target.id,'leave'); END LOOP;
 ELSIF TG_OP='UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('approved','rejected') THEN
  PERFORM public.jb_queue_push_event('leavechange:decision:'||NEW.id::text||':'||NEW.status,NEW.employee_id,'leave');
 END IF;
 RETURN NEW;
END;$fn$;
DROP TRIGGER IF EXISTS jb_push_leave_change_events_v34 ON public.jb_leave_change_requests;
CREATE TRIGGER jb_push_leave_change_events_v34 AFTER INSERT OR UPDATE OF status ON public.jb_leave_change_requests
FOR EACH ROW EXECUTE FUNCTION public.jb_push_leave_change_event_trigger();
COMMIT;
SELECT to_regclass('public.jb_push_outbox') AS outbox_table;
