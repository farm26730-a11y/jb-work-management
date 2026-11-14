-- 연차 자동 계산을 기존 직원 휴무 승인과 연결하는 신규 RPC만 추가.
-- 기존 운영 승인 RPC/테이블 무변경. 실제 확정 근태가 없는 경우 입사일 기준 '잠정' 계산으로 명시.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_auto_check_request_v13(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE v_original jsonb;v_item jsonb;v_status text;v_days numeric;v_balance numeric;v_date date;v_end date;
BEGIN
 v_original:=public.jb_annual_leave_check_request_v13(p_request_id);
 v_status:=v_original->>'status';
 IF v_status='not_annual' OR v_status='multi_day_review' THEN RETURN v_original; END IF;
 SELECT value INTO v_item
 FROM pg_catalog.jsonb_array_elements(public.jb_annual_leave_auto_overview_v13()->'items') AS t(value)
 WHERE value->>'employee_id'=v_original->>'employee_id' LIMIT 1;
 IF v_item IS NULL OR v_item->>'status'<>'estimated_attendance' THEN
    RETURN v_original; 
 END IF;
 v_date:=(v_original->>'start_date')::date;
 v_end:=(v_original->>'end_date')::date;
 v_days:=(v_original->>'required_days')::numeric;
 v_balance:=NULLIF(v_item->>'available_days','')::numeric;
 IF v_date IS NULL OR v_end IS NULL OR v_days IS NULL OR v_balance IS NULL THEN RETURN v_original; END IF;
 IF v_date<(v_item->>'cycle_start')::date OR v_end>(v_item->>'cycle_end')::date THEN
   RETURN v_original || pg_catalog.jsonb_build_object('status','outside_cycle');
 END IF;
 IF v_date>(v_original->>'as_of')::date THEN
   RETURN v_original || pg_catalog.jsonb_build_object('status','future_request_review');
 END IF;
 RETURN v_original || pg_catalog.jsonb_build_object(
   'status',CASE WHEN v_balance>=v_days THEN 'ready_auto_provisional' ELSE 'insufficient_auto' END,
   'available_days',v_balance,'overview_status','estimated_attendance',
   'calculation_mode','automatic_hire_date_provisional');
END;
$function$;
REVOKE ALL ON FUNCTION public.jb_annual_leave_auto_check_request_v13(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_auto_check_request_v13(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.jb_annual_leave_auto_review_request_v13(
 p_request_id uuid, p_decision text,
 p_approval_days numeric DEFAULT NULL::numeric,
 p_review_note text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE v_check jsonb; v_note text:=pg_catalog.btrim(COALESCE(p_review_note,''));v_status text;
BEGIN
 IF p_decision='approved' THEN
   v_check:=public.jb_annual_leave_auto_check_request_v13(p_request_id);
   v_status:=v_check->>'status';
   IF v_status='ready_auto_provisional' AND length(v_note)<8 THEN
     v_note:='입사일 자동 산정 적용(근태 출근율 미검증, 담당자 휴무 승인)';
   ELSIF v_status='insufficient_auto' AND length(v_note)<8 THEN
     RAISE EXCEPTION '자동 계산 잔여일수 부족: 승인하려면 근거를 8자 이상 남겨 주세요';
   END IF;
 END IF;
 RETURN public.jb_annual_leave_review_request_v13(
   p_request_id,p_decision,p_approval_days,NULLIF(v_note,''));
END;
$function$;
REVOKE ALL ON FUNCTION public.jb_annual_leave_auto_review_request_v13(uuid,text,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_auto_review_request_v13(uuid,text,numeric,text) TO authenticated;
