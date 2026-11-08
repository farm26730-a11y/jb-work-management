-- [시험용 설치 초안 / 운영 DB 실행 금지]
-- JB 업무관리 V1.3 알림 수신 범위·함수 권한 보강
-- 실제 운영 함수 정의에서 수신 조건만 국소 수정한 테스트 초안.
-- JB-DEV에 스키마가 없으므로 DB 실행/실계정 테스트는 아직 하지 못함.
-- 운영 DB에 적용하지 않음. 기존 발송 대기열·업무·근태 데이터는 건드리지 않음.
BEGIN;

-- jb_push_leave_change_event_trigger: 기존 함수 내용 보존, 수신 범위 조건만 변경
CREATE OR REPLACE FUNCTION public.jb_push_leave_change_event_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_target record;
BEGIN
  SELECT app_role INTO v_role
  FROM public.jb_employees
  WHERE id = NEW.employee_id;

  IF TG_OP = 'INSERT'
     AND NEW.status = 'pending' THEN

    FOR v_target IN
      SELECT id
      FROM public.jb_employees
      WHERE active IS TRUE
        AND (
          (v_role = 'staff' AND app_role = 'manager'
           AND department_id = (SELECT department_id FROM public.jb_employees WHERE id=NEW.employee_id))
          OR
          (v_role = 'manager' AND app_role = 'owner')
        )
    LOOP
      PERFORM public.jb_queue_push_event(
        'leavechange:new:' || NEW.id::text,
        v_target.id,
        'leave'
      );
    END LOOP;

  ELSIF TG_OP = 'UPDATE'
    AND OLD.status IS DISTINCT FROM NEW.status
    AND NEW.status IN (
      'approved','rejected'
    ) THEN

    PERFORM public.jb_queue_push_event(
      'leavechange:decision:' || NEW.id::text
        || ':' || NEW.status,
      NEW.employee_id,
      'leave'
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- jb_push_report_request_trigger_v14: 기존 함수 내용 보존, 수신 범위 조건만 변경
CREATE OR REPLACE FUNCTION public.jb_push_report_request_trigger_v14()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_target record;
BEGIN
    -- 비활성 직원의 요청은 푸시 생성 제외
    IF NOT EXISTS (
        SELECT 1
        FROM public.jb_employees requester
        WHERE requester.id = NEW.requester_id
          AND requester.active IS TRUE
    ) THEN
        RETURN NEW;
    END IF;

    -- 선택한 보고 대상에만 알림 전송
    FOR v_target IN
        SELECT e.id
        FROM public.jb_employees e
        WHERE e.active IS TRUE
          AND e.id <> NEW.requester_id
          AND (
              (
                  NEW.target_owner IS TRUE
                  AND e.app_role = 'owner'
              )
              OR (
                  NEW.target_owner IS FALSE
                  AND e.app_role = 'manager'
                  AND ((SELECT app_role FROM public.jb_employees WHERE id=NEW.requester_id) <> 'staff'
                    OR e.department_id = (SELECT department_id FROM public.jb_employees WHERE id=NEW.requester_id))
              )
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

-- jb_submit_report_core_v14: 기존 함수 내용 보존, 수신 범위 조건만 변경
CREATE OR REPLACE FUNCTION public.jb_submit_report_core_v14(p_task_id uuid, p_body text, p_target_owner boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_me public.jb_employees%ROWTYPE;
    v_task public.jb_tasks%ROWTYPE;
    v_note text;
    v_request_id uuid;
    v_comment_id uuid;
    v_existing boolean := false;
    v_owner_target boolean;
    v_receiver record;
    v_key text;
BEGIN
    SELECT *
    INTO v_me
    FROM public.jb_employees
    WHERE auth_user_id = auth.uid()
      AND active IS TRUE
    LIMIT 1;

    IF NOT FOUND
       OR v_me.app_role NOT IN ('staff', 'manager') THEN
        RAISE EXCEPTION '활성 직원 또는 부서장 계정이 필요합니다.';
    END IF;

    SELECT *
    INTO v_task
    FROM public.jb_tasks
    WHERE id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '업무를 찾을 수 없습니다.';
    END IF;

    IF v_task.assignee_id IS DISTINCT FROM v_me.id
       AND v_task.created_by IS DISTINCT FROM v_me.id THEN
        RAISE EXCEPTION '본인이 담당하거나 작성한 업무만 보고할 수 있습니다.';
    END IF;

    v_note := btrim(coalesce(p_body, ''));

    IF length(v_note) NOT BETWEEN 1 AND 2000 THEN
        RAISE EXCEPTION '보고 내용은 1~2000자로 입력하세요.';
    END IF;

    -- 부서장 보고는 대표님에게 전달
    v_owner_target :=
        p_target_owner IS TRUE;

    -- 동일 업무·직원 동시 보고 충돌 방지
    PERFORM pg_advisory_xact_lock(
        hashtext(p_task_id::text),
        hashtext(v_me.id::text)
    );

    -- 기존 미확인 요청을 우선 조회
    SELECT id
    INTO v_request_id
    FROM public.jb_task_report_requests
    WHERE task_id = p_task_id
      AND requester_id = v_me.id
      AND acknowledged_at IS NULL
    FOR UPDATE;

    v_existing := FOUND;

    -- 보고 댓글은 항상 새로 기록
    INSERT INTO public.jb_task_comments (
        task_id, author_id, body
    )
    VALUES (
        p_task_id, v_me.id, v_note
    )
    RETURNING id INTO v_comment_id;

    IF v_existing THEN
        -- 미확인 요청은 중복 생성하지 않음
        UPDATE public.jb_task_report_requests
        SET note = v_note,
            target_owner = v_owner_target
        WHERE id = v_request_id;

        -- 반복 보고에는 고유 알림 키 사용
        v_key := 'report:comment:' || v_comment_id::text;
    ELSE
        INSERT INTO public.jb_task_report_requests (
            task_id, requester_id, note, target_owner
        )
        VALUES (
            p_task_id, v_me.id, v_note, v_owner_target
        )
        RETURNING id INTO v_request_id;

        -- 기존 INSERT 트리거와 중복 발송 방지
        v_key := 'report:' || v_request_id::text;
    END IF;

    -- 보고 대상별 알림 대기열 등록
    FOR v_receiver IN
        SELECT id
        FROM public.jb_employees
        WHERE active IS TRUE
          AND id <> v_me.id
          AND (
              (
                  v_owner_target IS TRUE
                  AND app_role = 'owner'
              )
              OR (
                  v_owner_target IS FALSE
                  AND app_role = 'manager'
                  AND (v_me.app_role <> 'staff' OR department_id = v_me.department_id)
                  
              )
          )
    LOOP
        PERFORM public.jb_queue_push_event(
            v_key,
            v_receiver.id,
            'report'
        );
    END LOOP;

    RETURN v_request_id;
END;
$function$;

-- 불필요한 비로그인 실행 권한 제한
REVOKE EXECUTE ON FUNCTION public.jb_is_active_manager() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_is_active_manager() TO authenticated;
-- 트리거 함수는 내부 트리거를 통해 계속 실행되며 클라이언트 호출 권한만 회수
REVOKE EXECUTE ON FUNCTION public.jb_push_task_insert_trigger() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.jb_push_leave_event_trigger() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.jb_push_leave_change_event_trigger() FROM PUBLIC, anon, authenticated;
COMMIT;

-- [조회용 검증 / 별도 실행]
-- SELECT p.oid::regprocedure::text AS function_name,
-- has_function_privilege('anon',p.oid,'EXECUTE') AS anon_can_execute
-- FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public' AND p.proname IN ('jb_is_active_manager','jb_push_task_insert_trigger','jb_push_leave_event_trigger','jb_push_leave_change_event_trigger');
-- [보류] jb_attendance_effective VIEW의 security_invoker 전환은 전사 휴무 표시를 깨뜨릴 수 있으므로 제외함.
-- [보류] 관리자 본인의 일반 보고 라우팅은 기존 함수 동작 유지(업무 규칙 확인 필요).
