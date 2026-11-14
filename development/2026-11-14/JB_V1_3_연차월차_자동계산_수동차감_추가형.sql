-- JB 업무관리 V1.3 · 입사일 기준 자동 계산(잠정) + 관리자 수동 차감
-- 기존 jb_annual_leave_overview_v13, 연차 장부, 기존 휴무 승인 함수 무변경.
-- 운영 DB에 새 RPC만 추가. 이 SQL만으로 기존 데이터/발생 장부를 쓰거나 수정하지 않음.
-- 월 개근·연 80% 출근율 판정에 필요한 전체 근태 기록이 없으므로 '자동 산정(출근 검증 전)'으로 표시.
-- SQL 설치 후 개발 GitHub development-test HTML에서만 새 RPC 호출.

CREATE OR REPLACE FUNCTION public.jb_annual_leave_auto_overview_v13()
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
 v_base jsonb; v_items jsonb := '[]'::jsonb; v_row jsonb;
 v_today date; v_hire date; v_next date;
 v_years integer; v_month integer; v_auto numeric(6,2);
 v_adjust numeric(6,2); v_used numeric(6,2);
 v_balance numeric(6,2); v_unverified integer; v_carry integer; v_status text;
BEGIN
 -- 기존 권한 검증 RPC가 본인/소속 직원/전체 관리자를 이미 제한함.
 v_base := public.jb_annual_leave_overview_v13();
 v_today := (v_base->>'as_of')::date;
 FOR v_row IN SELECT value FROM pg_catalog.jsonb_array_elements(v_base->'items')
 LOOP
   IF v_row->>'hire_date' IS NULL THEN
     v_items := v_items || pg_catalog.jsonb_build_array(v_row || pg_catalog.jsonb_build_object(
       'accrual_mode','hire_date_auto','verification','hire_date_missing',
       'automatic_accrued_days',NULL,'attendance_verified',false));
     CONTINUE;
   END IF;
   v_hire := (v_row->>'hire_date')::date;
   IF v_hire > v_today THEN
     v_items := v_items || pg_catalog.jsonb_build_array(v_row || pg_catalog.jsonb_build_object(
       'accrual_mode','hire_date_auto','verification','future_hire_date',
       'status','future_hire_date','automatic_accrued_days',0,'granted_days',0,
       'available_days',NULL,'attendance_verified',false));
     CONTINUE;
   END IF;
   v_years := (v_row->>'years_completed')::integer;
   v_auto := 0;
   v_next := NULL;
   IF v_years = 0 THEN
     FOR v_month IN 1..11 LOOP
       IF (v_hire + pg_catalog.make_interval(months=>v_month))::date <= v_today THEN
         v_auto := v_auto + 1;
       ELSIF v_next IS NULL THEN
         v_next := (v_hire + pg_catalog.make_interval(months=>v_month))::date;
       END IF;
     END LOOP;
     IF v_next IS NULL THEN v_next := (v_hire + pg_catalog.make_interval(years=>1))::date; END IF;
   ELSE
     v_auto := LEAST(25,15+pg_catalog.floor((v_years-1)::numeric/2));
     v_next := (v_hire + pg_catalog.make_interval(years=>v_years+1))::date;
   END IF;

   v_adjust := COALESCE((v_row->>'adjustment_days')::numeric,0);
   v_used := COALESCE((v_row->>'used_or_reserved_days')::numeric,0);
   v_unverified := COALESCE((v_row->>'unverified_count')::integer,0);
   v_carry := COALESCE((v_row->>'prior_carry_count')::integer,0);
   v_balance := CASE WHEN v_unverified>0 OR v_carry>0 THEN NULL
                     ELSE v_auto+v_adjust-v_used END;
   v_status := CASE WHEN v_unverified>0 THEN 'needs_usage_review'
                    WHEN v_carry>0 THEN 'needs_carryover_review'
                    ELSE 'estimated_attendance' END;
   -- 윤일 입사자의 2/28 비윤년 주기는 AGE()와 실제 날짜 더하기의
   -- 주년 판정이 어긋날 수 있으므로 잔액을 확정하지 않고 예외로 분류.
   IF pg_catalog.extract(month FROM v_hire)=2
      AND pg_catalog.extract(day FROM v_hire)=29
      AND (v_hire+pg_catalog.make_interval(years=>v_years+1))::date<=v_today THEN
     v_balance := NULL;
     v_status := 'needs_calendar_review';
   END IF;
   v_items := v_items || pg_catalog.jsonb_build_array(v_row || pg_catalog.jsonb_build_object(
     'status',v_status,
     'accrual_mode','hire_date_auto',
     'verification','attendance_unverified',
     'attendance_verified',false,
     'automatic_accrued_days',v_auto,
     'granted_days',v_auto,
     'available_days',v_balance,
     'next_grant_due',v_next,
     'missing_due_count',0,
     'due_grants','[]'::jsonb,
     'previous_manual_grants',v_row->'grant_history'
   ));
 END LOOP;
 RETURN pg_catalog.jsonb_build_object(
   'as_of',v_today,'calculation_mode','automatic_hire_date_provisional',
   'attendance_verified',false,'items',v_items);
END;
$function$;

REVOKE ALL ON FUNCTION public.jb_annual_leave_auto_overview_v13() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_auto_overview_v13() TO authenticated;

-- 양수로 입력한 일수만 '차감' 처리; 원래 RPC가 직원/부서/대표 권한을 다시 확인.
-- 같은 직원의 두 차감을 직렬화해 잔여 조회 후 과차감을 방지.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_deduct_auto_v13(
  p_employee_id uuid, p_days numeric, p_reason text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE v_item jsonb; v_balance numeric;
BEGIN
 IF (SELECT auth.uid()) IS NULL THEN
   RAISE EXCEPTION '로그인한 직원만 차감을 요청할 수 있습니다' USING ERRCODE='42501';
 END IF;
 IF p_employee_id IS NULL OR p_days IS NULL OR p_days < 0.5 OR p_days > 25
   OR p_days*2 <> pg_catalog.trunc(p_days*2) THEN
   RAISE EXCEPTION '차감 일수는 0.5일 단위로 0.5~25일을 입력하세요';
 END IF;
 IF pg_catalog.length(pg_catalog.btrim(COALESCE(p_reason,''))) < 4 THEN
   RAISE EXCEPTION '차감 사유를 4자 이상 입력하세요';
 END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(52114,pg_catalog.hashtext(p_employee_id::text));
 SELECT value INTO v_item
 FROM pg_catalog.jsonb_array_elements(public.jb_annual_leave_auto_overview_v13()->'items') AS t(value)
 WHERE value->>'employee_id'=p_employee_id::text;
 IF v_item IS NULL THEN
   RAISE EXCEPTION '조회 권한이 없거나 직원 입사일이 등록되지 않았습니다' USING ERRCODE='42501';
 END IF;
 v_balance := NULLIF(v_item->>'available_days','')::numeric;
 IF v_balance IS NULL THEN RAISE EXCEPTION '연차 사용·이월 기록 확인 후 차감할 수 있습니다'; END IF;
 IF v_balance < p_days THEN RAISE EXCEPTION '산정 잔여일수보다 많이 차감할 수 없습니다'; END IF;
 RETURN public.jb_annual_leave_adjust_v13(
   p_employee_id,-p_days,'[수동 차감] '||pg_catalog.btrim(p_reason));
END;
$function$;

REVOKE ALL ON FUNCTION public.jb_annual_leave_deduct_auto_v13(uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_deduct_auto_v13(uuid,numeric,text) TO authenticated;
