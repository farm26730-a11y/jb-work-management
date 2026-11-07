-- [설치 SQL / 운영 DB 2026-11-07 적용됨]
-- 직원 휴무·연장근무 신청: 동일 부서 관리자만 조회/승인/푸시.
-- 기존 role, 계정, 휴무 데이터, 업무·식사 기능 변경 없음.
-- 이미 운영 DB에 적용됐으므로 불필요한 재실행 금지.
BEGIN;
CREATE OR REPLACE FUNCTION public.jb_leave_visible_requests()
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH caller AS (
    SELECT e.id, e.app_role, e.department_id
    FROM public.jb_employees e
    WHERE e.auth_user_id = (SELECT auth.uid())
      AND e.active IS TRUE
      AND e.app_role IN ('owner','manager','staff')
    LIMIT 1
  ),
  visible AS (
    SELECT
      r.*,
      applicant.app_role AS applicant_role,
      applicant.department_id
        AS applicant_department_id,
      (
        r.approval_status = 'pending'
        AND r.employee_id <> me.id
        AND (
          (
            me.app_role = 'owner'
            AND applicant.app_role = 'manager'
          )
          OR
          (
            me.app_role = 'manager'
            AND applicant.app_role = 'staff'
            AND me.department_id IS NOT NULL
            AND applicant.department_id = me.department_id
          )
        )
      ) AS can_review
    FROM public.jb_leave_requests r
    JOIN public.jb_employees applicant
      ON applicant.id = r.employee_id
    CROSS JOIN caller me
    WHERE
      r.employee_id = me.id
      OR me.app_role = 'owner'
      OR (
        me.app_role = 'manager'
        AND applicant.app_role = 'staff'
            AND me.department_id IS NOT NULL
            AND applicant.department_id = me.department_id
      )
  )
  SELECT to_jsonb(v)
  FROM visible v
  ORDER BY v.created_at DESC
  LIMIT 1000;
$function$
;

CREATE OR REPLACE FUNCTION public.jb_review_leave_companywide(p_request_id uuid, p_decision text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_me public.jb_employees%ROWTYPE;
  v_request public.jb_leave_requests%ROWTYPE;
  v_applicant public.jb_employees%ROWTYPE;
BEGIN
  IF p_request_id IS NULL
     OR p_decision IS NULL
     OR p_decision NOT IN ('approved','rejected')
  THEN
    RAISE EXCEPTION '승인 또는 반려 값이 올바르지 않습니다';
  END IF;

  -- 현재 로그인한 활성 직원 확인
  SELECT *
  INTO v_me
  FROM public.jb_employees
  WHERE auth_user_id = (SELECT auth.uid())
    AND active IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION '활성 직원 계정이 아닙니다';
  END IF;

  -- 신청 기록 잠금: 중복 승인 방지
  SELECT *
  INTO v_request
  FROM public.jb_leave_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '신청 내역을 찾을 수 없습니다';
  END IF;

  IF v_request.approval_status <> 'pending' THEN
    RAISE EXCEPTION '이미 처리된 신청입니다';
  END IF;

  -- 자기 승인 금지
  IF v_request.employee_id = v_me.id THEN
    RAISE EXCEPTION '본인 신청은 직접 승인할 수 없습니다';
  END IF;

  SELECT *
  INTO v_applicant
  FROM public.jb_employees
  WHERE id = v_request.employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '신청 직원 정보를 찾을 수 없습니다';
  END IF;

  -- 대표는 관리자 신청만 승인
  -- 관리자는 모든 일반 직원 신청 승인
  -- 부서는 비교하지 않음
  IF NOT (
    (
      v_me.app_role = 'owner'
      AND v_applicant.app_role = 'manager'
    )
    OR
    (
      v_me.app_role = 'manager'
      AND v_applicant.app_role = 'staff'
      AND v_me.department_id IS NOT NULL
      AND v_me.department_id = v_applicant.department_id
    )
  ) THEN
    RAISE EXCEPTION '해당 신청의 승인 권한이 없습니다';
  END IF;

  UPDATE public.jb_leave_requests
  SET
    approval_status = p_decision,
    reviewed_by = v_me.id,
    reviewed_at = now()
  WHERE id = p_request_id
    AND approval_status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION '승인 처리에 실패했습니다';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'request_id', p_request_id,
    'decision', p_decision,
    'reviewed_by', v_me.id
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.jb_leave_change_visible()
 RETURNS TABLE(id uuid, request_id uuid, employee_id uuid, action text, proposed jsonb, original jsonb, status text, requested_at timestamp with time zone, reviewed_at timestamp with time zone, can_review boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 with me as (select id,app_role,department_id from public.jb_employees where auth_user_id=auth.uid() and active=true limit 1)
 select c.id,c.request_id,c.employee_id,c.action,c.proposed,c.original,c.status,c.requested_at,c.reviewed_at,
 (c.status='pending' and c.employee_id<>me.id and
    ((me.app_role='owner' and applicant.app_role='manager') or (me.app_role='manager' and applicant.app_role='staff' and me.department_id is not null and me.department_id=applicant.department_id)))
 from public.jb_leave_change_requests c
 join public.jb_employees applicant on applicant.id=c.employee_id
 cross join me
 where c.employee_id=me.id or (me.app_role='owner' and applicant.app_role='manager') or (me.app_role='manager' and applicant.app_role='staff' and me.department_id is not null and me.department_id=applicant.department_id)
 order by c.requested_at desc limit 500;
$function$
;

CREATE OR REPLACE FUNCTION public.jb_review_leave_change(p_change_id uuid, p_decision text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me public.jb_employees%rowtype; v_c public.jb_leave_change_requests%rowtype; v_app public.jb_employees%rowtype; v_old public.jb_leave_requests%rowtype; v_new public.jb_leave_requests%rowtype;
begin
 select * into v_me from public.jb_employees where auth_user_id=auth.uid() and active=true;
 if not found then raise exception '현재 직원 계정이 아닙니다'; end if;
 if p_decision not in ('approved','rejected') then raise exception '처리 종류 오류'; end if;
 select * into v_c from public.jb_leave_change_requests where id=p_change_id for update;
 if not found or v_c.status<>'pending' then raise exception '검토 가능한 요청이 아닙니다'; end if;
 select * into v_app from public.jb_employees where id=v_c.employee_id;
 if v_me.id=v_app.id or not ((v_me.app_role='owner' and v_app.app_role='manager') or (v_me.app_role='manager' and v_app.app_role='staff' and v_me.department_id is not null and v_me.department_id=v_app.department_id)) then raise exception '승인 권한이 없습니다'; end if;
 select * into v_old from public.jb_leave_requests where id=v_c.request_id for update;
 if not found or v_old.employee_id<>v_c.employee_id or v_old.approval_status<>'approved' or to_jsonb(v_old)<>v_c.original then raise exception '원본 신청이 변경되었습니다. 다시 확인해 주세요'; end if;
 if p_decision='approved' then
   if v_c.action='edit' then
     update public.jb_leave_requests set request_type=v_c.proposed->>'request_type',start_date=(v_c.proposed->>'start_date')::date,
     end_date=(v_c.proposed->>'end_date')::date,reason=v_c.proposed->>'reason',
     overtime_start_time=(v_c.proposed->>'overtime_start_time')::time,
     overtime_end_time=(v_c.proposed->>'overtime_end_time')::time
     where id=v_c.request_id returning * into v_new;
     insert into public.jb_leave_request_audit(request_id,employee_id,action,before_row,after_row,actor_user_id)
     values(v_c.request_id,v_c.employee_id,'edit',to_jsonb(v_old),to_jsonb(v_new),auth.uid());
   else
     insert into public.jb_leave_request_audit(request_id,employee_id,action,before_row,actor_user_id)
     values(v_c.request_id,v_c.employee_id,'cancel',to_jsonb(v_old),auth.uid());
     -- 원본 조회함수/집계가 기존 상태값만 지원할 수 있어 기존 신청은 삭제, 이력은 보존
     delete from public.jb_leave_requests where id=v_c.request_id;
   end if;
 end if;
 update public.jb_leave_change_requests set status=p_decision,reviewed_by=auth.uid(),reviewed_at=now() where id=p_change_id;
end; $function$
;

CREATE OR REPLACE FUNCTION public.jb_push_leave_event_trigger()
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
     AND NEW.approval_status = 'pending' THEN

    FOR v_target IN
      SELECT id
      FROM public.jb_employees
      WHERE active IS TRUE
        AND (
          (v_role = 'staff' AND app_role = 'manager' AND department_id IS NOT NULL AND department_id=(SELECT department_id FROM public.jb_employees WHERE id=NEW.employee_id))
          OR
          (v_role = 'manager' AND app_role = 'owner')
        )
    LOOP
      PERFORM public.jb_queue_push_event(
        'leave:new:' || NEW.id::text,
        v_target.id,
        'leave'
      );
    END LOOP;

  ELSIF TG_OP = 'UPDATE'
    AND OLD.approval_status
        IS DISTINCT FROM NEW.approval_status
    AND NEW.approval_status IN (
      'approved','rejected'
    ) THEN

    PERFORM public.jb_queue_push_event(
      'leave:decision:' || NEW.id::text
        || ':' || NEW.approval_status,
      NEW.employee_id,
      'leave'
    );
  END IF;

  RETURN NEW;
END;
$function$
;
COMMIT;
