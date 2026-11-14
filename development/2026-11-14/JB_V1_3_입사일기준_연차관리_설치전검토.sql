-- JB 업무관리 V1.3 / 입사일 기준 연차(개발시험용)
-- 적용 대상은 JB-DEV이며 운영 Supabase에는 실행하지 말 것.
-- 기존 직원 입사일은 모름(NULL)으로 두며 임의 추정하지 않음.
-- 월 개근/연 80% 출근율은 관리자가 별도 확인 후 발생 확정.
-- 반차는 0.5일, 다일 연차는 소정근로일 확인 후 사용일수 확정.
-- 업무 초기화 함수는 신규 세 테이블을 24개 초기화 대상으로 포함함.
-- 개인 인사 및 휴가 기록을 포함하므로 운영 적용 전에 백업, 법률 검토 필수.

ALTER TABLE public.jb_employees
  ADD COLUMN IF NOT EXISTS hire_date date;

CREATE TABLE IF NOT EXISTS public.jb_annual_leave_grants_v13 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  grant_kind text NOT NULL CHECK (grant_kind IN ('monthly','yearly')),
  period_index integer NOT NULL CHECK (period_index BETWEEN 1 AND 50),
  period_start date NOT NULL,
  period_end date NOT NULL,
  grant_date date NOT NULL,
  expires_on date NOT NULL,
  days numeric(6,2) NOT NULL CHECK (days > 0 AND days <= 25),
  verification_note text NOT NULL CHECK (length(btrim(verification_note)) >= 4),
  verified_by uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT jb_annual_grant_unique_v13 UNIQUE(employee_id,grant_kind,period_index),
  CONSTRAINT jb_annual_grant_dates_v13 CHECK(period_start<=period_end AND period_end<grant_date AND grant_date<=expires_on)
);

CREATE TABLE IF NOT EXISTS public.jb_annual_leave_adjustments_v13 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  effective_date date NOT NULL DEFAULT current_date,
  days numeric(6,2) NOT NULL CHECK (days BETWEEN -25 AND 25 AND days <> 0),
  reason text NOT NULL CHECK (length(btrim(reason)) >= 4),
  recorded_by uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.jb_annual_leave_usage_v13 (
  request_id uuid PRIMARY KEY REFERENCES public.jb_leave_requests(id) ON DELETE CASCADE,
  days numeric(6,2) NOT NULL CHECK (days > 0 AND days <= 31),
  note text NOT NULL CHECK (length(btrim(note)) >= 4),
  confirmed_by uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS jb_annual_grants_employee_date_idx_v13
 ON public.jb_annual_leave_grants_v13(employee_id,grant_date);
CREATE INDEX IF NOT EXISTS jb_annual_adjustments_employee_date_idx_v13
 ON public.jb_annual_leave_adjustments_v13(employee_id,effective_date);

ALTER TABLE public.jb_annual_leave_grants_v13 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jb_annual_leave_adjustments_v13 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jb_annual_leave_usage_v13 ENABLE ROW LEVEL SECURITY;
-- 데이터 접근은 반드시 권한 검증이 있는 RPC 경유. 기본 직접 접근 금지.
REVOKE ALL ON TABLE public.jb_annual_leave_grants_v13, public.jb_annual_leave_adjustments_v13,
  public.jb_annual_leave_usage_v13 FROM PUBLIC, anon, authenticated;

-- 관리자/대표만 입사일 수정. 실제 연차 발생 기록 후에는 입사일 변경 금지.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_set_hire_date_v13(p_employee_id uuid,p_hire_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_target public.jb_employees%ROWTYPE;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_target FROM public.jb_employees WHERE id=p_employee_id FOR UPDATE;
 IF v_me.id IS NULL OR v_target.id IS NULL OR
    NOT (v_me.app_role='owner' OR
         (v_me.app_role='manager' AND v_target.app_role='staff' AND
          v_me.department_id IS NOT NULL AND v_me.department_id=v_target.department_id)) THEN
   RAISE EXCEPTION '입사일을 수정할 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_target.app_role='owner' OR p_hire_date IS NULL OR p_hire_date>current_date OR p_hire_date<DATE '1950-01-01' THEN
   RAISE EXCEPTION '유효한 입사일을 입력하세요';
 END IF;
 IF v_target.hire_date IS DISTINCT FROM p_hire_date AND
   (EXISTS(SELECT 1 FROM public.jb_annual_leave_grants_v13 WHERE employee_id=p_employee_id)
    OR EXISTS(SELECT 1 FROM public.jb_annual_leave_adjustments_v13 WHERE employee_id=p_employee_id)) THEN
   RAISE EXCEPTION '연차 기록이 존재합니다. 입사일 변경 전 기록 정정 절차를 확인해야 합니다';
 END IF;
 UPDATE public.jb_employees SET hire_date=p_hire_date WHERE id=p_employee_id;
END;$f$;

-- 월 개근/연 출근율을 사람이 확인한 뒤 법정 발생량 확정.
-- p_period_index: 월별 1~11, 연차별 1=첫 1년 완료/2=둘째 1년 완료...
CREATE OR REPLACE FUNCTION public.jb_annual_leave_confirm_grant_v13(
 p_employee_id uuid,p_grant_kind text,p_period_index integer,p_verification_note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_target public.jb_employees%ROWTYPE;
 v_start date; v_grant date; v_expire date; v_days numeric(6,2); v_id uuid;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_target FROM public.jb_employees WHERE id=p_employee_id AND active IS TRUE FOR UPDATE;
 IF v_me.id IS NULL OR v_target.id IS NULL OR NOT (
     v_me.app_role='owner' OR
     (v_me.app_role='manager' AND v_target.app_role='staff' AND v_me.department_id IS NOT NULL AND v_me.department_id=v_target.department_id)) THEN
   RAISE EXCEPTION '연차 발생을 확정할 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_target.app_role='owner' OR v_target.hire_date IS NULL THEN RAISE EXCEPTION '직원의 입사일 등록이 먼저 필요합니다'; END IF;
 IF length(btrim(coalesce(p_verification_note,'')))<4 THEN RAISE EXCEPTION '개근 또는 출근율 확인 근거를 4자 이상 입력하세요'; END IF;
 IF p_grant_kind='monthly' AND p_period_index BETWEEN 1 AND 11 THEN
   v_start=(v_target.hire_date+make_interval(months=>p_period_index-1))::date;
   v_grant=(v_target.hire_date+make_interval(months=>p_period_index))::date;
   v_expire=(v_target.hire_date+make_interval(years=>1))::date-1;
   v_days=1;
 ELSIF p_grant_kind='yearly' AND p_period_index BETWEEN 1 AND 50 THEN
   v_start=(v_target.hire_date+make_interval(years=>p_period_index-1))::date;
   v_grant=(v_target.hire_date+make_interval(years=>p_period_index))::date;
   v_expire=(v_target.hire_date+make_interval(years=>p_period_index+1))::date-1;
   v_days=LEAST(25,15+floor((p_period_index-1)::numeric/2));
 ELSE RAISE EXCEPTION '잘못된 연차 발생 구분 또는 회차입니다'; END IF;
 IF v_grant>current_date THEN RAISE EXCEPTION '아직 발생일이 도래하지 않았습니다'; END IF;
 IF v_expire<current_date THEN RAISE EXCEPTION '기존 발생분의 사용기한이 지났습니다. 과거 기록 정정 절차로 처리하세요'; END IF;
 INSERT INTO public.jb_annual_leave_grants_v13
 (employee_id,grant_kind,period_index,period_start,period_end,grant_date,expires_on,days,verification_note,verified_by)
 VALUES (p_employee_id,p_grant_kind,p_period_index,v_start,v_grant-1,v_grant,v_expire,v_days,btrim(p_verification_note),v_me.id)
 ON CONFLICT(employee_id,grant_kind,period_index) DO NOTHING RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION '이미 확정된 발생 회차입니다. 중복 적립할 수 없습니다'; END IF;
 RETURN v_id;
END;$f$;

-- 이전 사용분/이월분 등의 입력. 기존 조정 기록을 덮어쓰지 않고 감사 내역으로 추가.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_adjust_v13(
 p_employee_id uuid,p_days numeric,p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_target public.jb_employees%ROWTYPE; v_id uuid;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_target FROM public.jb_employees WHERE id=p_employee_id AND active IS TRUE;
 IF v_me.id IS NULL OR v_target.id IS NULL OR NOT (v_me.app_role='owner' OR
  (v_me.app_role='manager' AND v_target.app_role='staff' AND v_me.department_id IS NOT NULL AND v_me.department_id=v_target.department_id)) THEN
   RAISE EXCEPTION '연차 조정 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_target.app_role='owner' OR v_target.hire_date IS NULL THEN RAISE EXCEPTION '유효한 직원 입사일부터 등록하세요'; END IF;
 IF p_days IS NULL OR p_days=0 OR abs(p_days)>25 OR length(btrim(coalesce(p_reason,'')))<4 THEN
   RAISE EXCEPTION '조정일수(±25일 이내)와 4자 이상의 사유가 필요합니다';
 END IF;
 INSERT INTO public.jb_annual_leave_adjustments_v13(employee_id,days,reason,recorded_by)
 VALUES (p_employee_id,p_days,btrim(p_reason),v_me.id) RETURNING id INTO v_id;
 RETURN v_id;
END;$f$;

-- 연속 날짜의 실제 연차 차감일수 확정 (휴무일 자동 제외 불가).
CREATE OR REPLACE FUNCTION public.jb_annual_leave_confirm_usage_v13(
 p_request_id uuid,p_days numeric,p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_employee public.jb_employees%ROWTYPE; v_request public.jb_leave_requests%ROWTYPE;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_request FROM public.jb_leave_requests WHERE id=p_request_id FOR UPDATE;
 SELECT * INTO v_employee FROM public.jb_employees WHERE id=v_request.employee_id;
 IF v_me.id IS NULL OR v_request.id IS NULL OR NOT (
   v_me.app_role='owner' OR
   (v_me.app_role='manager' AND v_employee.app_role='staff' AND v_me.department_id IS NOT NULL AND v_me.department_id=v_employee.department_id)) THEN
   RAISE EXCEPTION '차감일수를 확인할 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_request.request_type<>'leave' OR v_request.approval_status<>'approved'
 OR v_request.leave_category NOT IN ('annual','half_am','half_pm') THEN
   RAISE EXCEPTION '승인된 연차/반차에만 적용할 수 있습니다';
 END IF;
 IF v_request.start_date=v_request.end_date THEN
   RAISE EXCEPTION '하루 연차 및 반차는 자동 집계됩니다';
 END IF;
 IF v_request.leave_category<>'annual' THEN
   RAISE EXCEPTION '연속 날짜 반차는 별도 검토가 필요합니다';
 END IF;
 IF p_days IS NULL OR p_days<=0 OR p_days>(v_request.end_date-v_request.start_date+1)
 OR length(btrim(coalesce(p_note,'')))<4 THEN
   RAISE EXCEPTION '소정근로일을 확인해 올바른 차감일수와 사유를 입력하세요';
 END IF;
 INSERT INTO public.jb_annual_leave_usage_v13(request_id,days,note,confirmed_by)
 VALUES(p_request_id,p_days,btrim(p_note),v_me.id)
 ON CONFLICT(request_id) DO UPDATE SET days=EXCLUDED.days,note=EXCLUDED.note,
 confirmed_by=EXCLUDED.confirmed_by,updated_at=now();
END;$f$;

-- 실시간 연차 현황. 본인은 본인만; 관리자는 본인+같은 부서 직원; 대표는 직원 전원.
-- 등록되지 않은 입사일/확인되지 않은 연속 휴가는 정확한 잔액을 숨기고 확인 필요로 표시.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_overview_v13()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_e public.jb_employees%ROWTYPE;
 v_years integer; v_from date; v_until date; v_grants numeric; v_adjust numeric;
 v_used numeric; v_unverified integer; v_next date; v_future_unverified jsonb;
 v_result jsonb:='[]'::jsonb; v_i integer; v_due date;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '직원 권한 확인 실패' USING ERRCODE='42501'; END IF;
 FOR v_e IN SELECT e.* FROM public.jb_employees e
   WHERE e.active IS TRUE AND e.app_role <> 'owner' AND
      (v_me.app_role='owner' OR e.id=v_me.id OR
       (v_me.app_role='manager' AND e.app_role='staff' AND
        v_me.department_id IS NOT NULL AND v_me.department_id=e.department_id))
   ORDER BY e.name, e.id
 LOOP
   IF v_e.hire_date IS NULL THEN
     v_result=v_result||jsonb_build_array(jsonb_build_object('employee_id',v_e.id,
       'name',v_e.name,'department_id',v_e.department_id,'role',v_e.app_role,
       'hire_date',NULL,'status','hire_date_missing','available_days',NULL));
     CONTINUE;
   END IF;
   v_years=GREATEST(0,extract(year from age(current_date,v_e.hire_date))::integer);
   v_from=(v_e.hire_date+make_interval(years=>v_years))::date;
   v_until=(v_e.hire_date+make_interval(years=>v_years+1))::date;
   SELECT COALESCE(sum(g.days),0) INTO v_grants FROM public.jb_annual_leave_grants_v13 g
    WHERE g.employee_id=v_e.id AND g.grant_date>=v_from AND g.grant_date<v_until
      AND g.grant_date<=current_date AND g.expires_on>=current_date;
   SELECT COALESCE(sum(a.days),0) INTO v_adjust FROM public.jb_annual_leave_adjustments_v13 a
    WHERE a.employee_id=v_e.id AND a.effective_date>=v_from AND a.effective_date<v_until;
   SELECT COALESCE(sum(CASE
      WHEN l.start_date<v_from OR l.end_date>=v_until THEN 0
      WHEN u.request_id IS NOT NULL THEN u.days
      WHEN l.start_date=l.end_date THEN CASE WHEN l.leave_category='annual' THEN 1 ELSE 0.5 END
      ELSE 0 END),0),
      COUNT(*) FILTER (WHERE l.start_date<v_from OR l.end_date>=v_until
                    OR (u.request_id IS NULL AND l.start_date<>l.end_date))
   INTO v_used,v_unverified
   FROM public.jb_leave_requests l
    LEFT JOIN public.jb_annual_leave_usage_v13 u ON u.request_id=l.id
   WHERE l.employee_id=v_e.id AND l.request_type='leave' AND l.approval_status='approved'
    AND l.leave_category IN ('annual','half_am','half_pm')
    AND l.start_date<v_until AND l.end_date>=v_from;
   SELECT coalesce(jsonb_agg(jsonb_build_object('request_id',x.id,'start_date',x.start_date,
     'end_date',x.end_date,'category',x.leave_category,'cross_cycle',x.cross_cycle)),'[]'::jsonb)
     INTO v_future_unverified
   FROM (
    SELECT l.id,l.start_date,l.end_date,l.leave_category,
      (l.start_date<v_from OR l.end_date>=v_until) AS cross_cycle
    FROM public.jb_leave_requests l
      LEFT JOIN public.jb_annual_leave_usage_v13 u ON u.request_id=l.id
    WHERE l.employee_id=v_e.id AND l.request_type='leave' AND l.approval_status='approved'
      AND l.leave_category IN ('annual','half_am','half_pm')
      AND l.start_date<v_until AND l.end_date>=v_from
      AND ((l.start_date<v_from OR l.end_date>=v_until) OR
           (u.request_id IS NULL AND l.start_date<>l.end_date))
    ORDER BY l.start_date DESC LIMIT 15
   ) x;
   v_next=NULL;
   IF v_years=0 THEN
      FOR v_i IN 1..11 LOOP
        v_due=(v_e.hire_date+make_interval(months=>v_i))::date;
        IF NOT EXISTS(SELECT 1 FROM public.jb_annual_leave_grants_v13 g
           WHERE g.employee_id=v_e.id AND g.grant_kind='monthly' AND g.period_index=v_i) THEN
           v_next=v_due; EXIT;
        END IF;
      END LOOP;
   ELSE
      -- 이번 연도 발생분이 미확정이면 해당 발생일, 이미 확정되면 다음 기념일을 표시.
      v_next=v_from;
      IF EXISTS(SELECT 1 FROM public.jb_annual_leave_grants_v13 g
                 WHERE g.employee_id=v_e.id AND g.grant_kind='yearly' AND g.period_index=v_years) THEN
         v_next=v_until;
      END IF;
   END IF;
   v_result=v_result||jsonb_build_array(jsonb_build_object(
      'employee_id',v_e.id,'name',v_e.name,'department_id',v_e.department_id,'role',v_e.app_role,
      'hire_date',v_e.hire_date,'status',CASE WHEN v_unverified>0 THEN 'needs_usage_review' ELSE 'ok' END,
      'cycle_start',v_from,'cycle_end',v_until-1,'years_completed',v_years,
      'granted_days',v_grants,'adjustment_days',v_adjust,'used_or_reserved_days',v_used,
      'unverified_count',v_unverified,'unverified_requests',v_future_unverified,
      'available_days',CASE WHEN v_unverified>0 THEN NULL ELSE v_grants+v_adjust-v_used END,
      'next_grant_due',v_next,'next_year_legal_days',LEAST(25,15+floor(v_years::numeric/2))
   ));
 END LOOP;
 RETURN jsonb_build_object('as_of',current_date,'items',v_result);
END;$f$;

-- 함수별 권한: 직접 테이블 조회 없음, 로그인된 직원만 RPC 호출.
REVOKE ALL ON FUNCTION public.jb_annual_leave_set_hire_date_v13(uuid,date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_confirm_grant_v13(uuid,text,integer,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_adjust_v13(uuid,numeric,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_confirm_usage_v13(uuid,numeric,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_overview_v13() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_set_hire_date_v13(uuid,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_confirm_grant_v13(uuid,text,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_adjust_v13(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_confirm_usage_v13(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_overview_v13() TO authenticated;

-- 운영 초기화의 신규 테이블 누락 방지: 총 24개 초기화, 8개 보존.
-- 함수 재정의만 수행하며 실제 초기화는 하지 않습니다.

CREATE OR REPLACE FUNCTION public.jb_owner_reset_operations_v11(p_phrase text, p_backup_confirmed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_owner uuid;
    v_reset regclass[] := ARRAY[
        'public.jb_announcement_reads'::regclass,
        'public.jb_announcements'::regclass,
        'public.jb_attendance'::regclass,
        'public.jb_attendance_notes'::regclass,
        'public.jb_events'::regclass,
        'public.jb_leave_change_requests'::regclass,
        'public.jb_leave_request_audit'::regclass,
        'public.jb_leave_requests'::regclass,
        'public.jb_notification_reads'::regclass,
        'public.jb_push_outbox'::regclass,
        'public.jb_task_comments'::regclass,
        'public.jb_task_history'::regclass,
        'public.jb_task_images'::regclass,
        'public.jb_task_report_requests'::regclass,
        'public.jb_tasks'::regclass,
        'public.jb_task_assignment_ack_v13'::regclass,
        'public.jb_task_comment_attention_v13'::regclass,
        'public.jb_meal_employee_v14'::regclass,
        'public.jb_meal_guest_v14'::regclass,
        'public.jb_meal_regular_orders_v15'::regclass,
        'public.jb_meal_rosters'::regclass,
        'public.jb_annual_leave_grants_v13'::regclass,
        'public.jb_annual_leave_adjustments_v13'::regclass,
        'public.jb_annual_leave_usage_v13'::regclass
    ];
    v_preserve regclass[] := ARRAY[
        'public.jb_departments'::regclass,
        'public.jb_employees'::regclass,
        'public.jb_meal_regular_people_v15'::regclass,
        'public.jb_meal_settings'::regclass,
        'public.jb_name_login_attempts'::regclass,
        'public.jb_push_subscriptions'::regclass,
        'public.jb_staff_contact_numbers'::regclass,
        'public.jb_task_templates'::regclass
    ];
    v_unknown text;
    v_blockers text;
BEGIN
    SELECT e.id INTO v_owner
      FROM public.jb_employees AS e
     WHERE e.auth_user_id = (SELECT auth.uid())
       AND e.app_role = 'owner'
       AND e.active IS TRUE
     LIMIT 1;
    IF v_owner IS NULL THEN
        RAISE EXCEPTION '재직 중인 대표 계정만 운영 기록을 초기화할 수 있습니다'
            USING ERRCODE = '42501';
    END IF;

    IF p_phrase IS DISTINCT FROM '운영기록 전체 초기화'
       OR p_backup_confirmed IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION '백업 완료 확인 및 정확한 확인 문구가 필요합니다';
    END IF;

    PERFORM pg_advisory_xact_lock(31535, 11);

    -- 미래에 새 JB 업무관리 테이블이 추가되면 누락/무단삭제 없이 즉시 중단.
    SELECT string_agg(c.oid::regclass::text, ', ' ORDER BY c.relname)
      INTO v_unknown
      FROM pg_class AS c
      JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r','p')
       AND c.relname LIKE 'jb_%'
       AND NOT (c.oid::regclass = ANY(v_reset))
       AND NOT (c.oid::regclass = ANY(v_preserve));
    IF v_unknown IS NOT NULL THEN
        RAISE EXCEPTION '초기화 대상이 지정되지 않은 새 테이블이 있습니다: %', v_unknown;
    END IF;

    -- 다른 스키마 포함 모든 FK 확인. 새 참조가 생겨도 CASCADE 강제삭제 금지.
    SELECT string_agg(
             format('%s → %s (%s)', fk.conrelid::regclass::text, fk.confrelid::regclass::text, fk.conname),
             ', ' ORDER BY fk.conname
           )
      INTO v_blockers
      FROM pg_constraint AS fk
     WHERE fk.contype = 'f'
       AND fk.confrelid::regclass = ANY(v_reset)
       AND NOT (fk.conrelid::regclass = ANY(v_reset));
    IF v_blockers IS NOT NULL THEN
        RAISE EXCEPTION '운영 기록 초기화 차단 외래키: %', v_blockers;
    END IF;

    -- 모든 참조 자식 테이블을 명시하고 RESTRICT로 의도치 않은 삭제를 막습니다.
    TRUNCATE TABLE
        public.jb_announcement_reads,
        public.jb_announcements,
        public.jb_attendance,
        public.jb_attendance_notes,
        public.jb_events,
        public.jb_leave_change_requests,
        public.jb_leave_request_audit,
        public.jb_leave_requests,
        public.jb_notification_reads,
        public.jb_push_outbox,
        public.jb_task_comments,
        public.jb_task_history,
        public.jb_task_images,
        public.jb_task_report_requests,
        public.jb_tasks,
        public.jb_task_assignment_ack_v13,
        public.jb_task_comment_attention_v13,
        public.jb_meal_employee_v14,
        public.jb_meal_guest_v14,
        public.jb_meal_regular_orders_v15,
        public.jb_meal_rosters,
        public.jb_annual_leave_grants_v13,
        public.jb_annual_leave_adjustments_v13,
        public.jb_annual_leave_usage_v13
    RESTRICT;

    RETURN jsonb_build_object(
        'success', true,
        'reset_table_count', cardinality(v_reset),
        'preserved_table_count', cardinality(v_preserve),
        'reset_at', now()
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.jb_owner_reset_operations_v11(text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_owner_reset_operations_v11(text,boolean) TO authenticated;
