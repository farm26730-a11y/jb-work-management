-- 운영 DB에 적용됨. 마감시간 07:00:00부터 거부하도록 > 를 >=로 변경.
CREATE OR REPLACE FUNCTION public.jb_meal_save_v13(p_date date, p_meal text, p_department uuid, p_employee_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_me public.jb_employees%rowtype; v_ids uuid[]; v_cutoff time;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=auth.uid() AND active=true LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION '활성 직원만 식사 명단을 저장할 수 있습니다'; END IF;
 IF p_date IS NULL OR p_meal NOT IN ('lunch','dinner') OR p_meal IS NULL THEN RAISE EXCEPTION '날짜 또는 식사 구분 오류'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.jb_departments WHERE id=p_department) THEN RAISE EXCEPTION '존재하지 않는 부서입니다'; END IF;
 SELECT dinner_deadline INTO v_cutoff FROM public.jb_meal_settings WHERE id=true;
 IF p_meal='dinner' AND (p_date < (now() AT TIME ZONE 'Asia/Seoul')::date OR
      (p_date=(now() AT TIME ZONE 'Asia/Seoul')::date AND (now() AT TIME ZONE 'Asia/Seoul')::time >= COALESCE(v_cutoff,'16:00'::time)))
 THEN RAISE EXCEPTION '저녁 신청 마감시간이 지났습니다'; END IF;
 v_ids := COALESCE(p_employee_ids,'{}'::uuid[]);
 -- 인원 ID는 해당 부서 활성 직원만 허용하고 중복을 금지
 IF EXISTS(SELECT 1 FROM unnest(v_ids) t(id) LEFT JOIN public.jb_employees e ON e.id=t.id AND e.active=true AND e.department_id=p_department WHERE e.id IS NULL)
    OR cardinality(v_ids) <> (SELECT count(DISTINCT id) FROM unnest(v_ids) t(id)) THEN
   RAISE EXCEPTION '선택 직원이 중복되거나 부서 소속이 아닙니다';
 END IF;
 INSERT INTO public.jb_meal_rosters(meal_date,meal_type,department_id,employee_ids,updated_by,updated_at)
 VALUES(p_date,p_meal,p_department,v_ids,v_me.id,now())
 ON CONFLICT(meal_date,meal_type,department_id) DO UPDATE
 SET employee_ids=excluded.employee_ids,updated_by=excluded.updated_by,updated_at=now();
END;$function$
;
