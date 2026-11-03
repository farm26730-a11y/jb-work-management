-- JB V1.4: 푸시 트리거가 요청자 역할이 아닌 target_owner로만 수신 대상을 판정
-- 적용: Supabase SQL Editor에서 수동 실행. GitHub 파일 저장만으로 운영 DB가 수정되지 않음.
BEGIN;

CREATE OR REPLACE FUNCTION public.jb_push_report_request_trigger_v14()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_target record;
BEGIN
    -- 최초 요청 INSERT에서만 실행. 비활성 요청자는 알림 생성하지 않음.
    IF NOT EXISTS (
        SELECT 1
        FROM public.jb_employees requester
        WHERE requester.id = NEW.requester_id
          AND requester.active IS TRUE
    ) THEN
        RETURN NEW;
    END IF;

    FOR v_target IN
        SELECT e.id
        FROM public.jb_employees e
        WHERE e.active IS TRUE
          AND e.id <> NEW.requester_id
          AND (
              (NEW.target_owner IS TRUE AND e.app_role = 'owner')
              OR
              (NEW.target_owner IS FALSE AND e.app_role = 'manager')
          )
    LOOP
        PERFORM public.jb_queue_push_event(
            'report:' || NEW.id::text,
            v_target.id,
            'report'
        );
    END LOOP;

    RETURN NEW;
END;
$function$;

COMMIT;

-- 검증: 기존 트리거가 활성화되어 있는지
SELECT t.tgname, t.tgenabled, p.proname
FROM pg_trigger t
JOIN pg_class c ON c.oid=t.tgrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN pg_proc p ON p.oid=t.tgfoid
WHERE n.nspname='public'
  AND c.relname='jb_task_report_requests'
  AND t.tgname='jb_push_report_requests_insert_v14';
