-- [설치용] JB 업무관리 V1.3 식사 신청 개선
-- 운영 DB에는 아직 실행하지 마세요. 시험 후 적용.
-- 기존 jb_meal_rosters / jb_meal_settings 테이블과 기존 기록은 보존.
BEGIN;

CREATE TABLE IF NOT EXISTS public.jb_meal_employee_v14 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meal_date date NOT NULL,
  meal_type text NOT NULL CHECK (meal_type IN ('lunch','dinner')),
  employee_id uuid NOT NULL REFERENCES public.jb_employees(id),
  department_id uuid NOT NULL REFERENCES public.jb_departments(id),
  location text,
  updated_by uuid NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT jb_meal_employee_v14_unique UNIQUE (meal_date, meal_type, employee_id),
  CONSTRAINT jb_meal_employee_v14_location CHECK (
    (meal_type='lunch' AND location IN ('농원','동이','쇼가든'))
    OR (meal_type='dinner' AND location IS NULL)
  )
);
CREATE INDEX IF NOT EXISTS jb_meal_employee_v14_date_idx
  ON public.jb_meal_employee_v14(meal_date,meal_type);

CREATE TABLE IF NOT EXISTS public.jb_meal_guest_v14 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meal_date date NOT NULL,
  meal_type text NOT NULL CHECK (meal_type IN ('lunch','dinner')),
  department_id uuid NOT NULL REFERENCES public.jb_departments(id),
  guest_kind text NOT NULL CHECK (guest_kind IN ('외부 작업자','방문객','협력업체','기타')),
  headcount integer NOT NULL CHECK (headcount BETWEEN 1 AND 200),
  location text,
  note text NOT NULL DEFAULT '' CHECK (length(note)<=100),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT jb_meal_guest_v14_location CHECK (
    (meal_type='lunch' AND location IN ('농원','동이','쇼가든'))
    OR (meal_type='dinner' AND location IS NULL)
  )
);
CREATE INDEX IF NOT EXISTS jb_meal_guest_v14_date_idx
  ON public.jb_meal_guest_v14(meal_date,meal_type);

ALTER TABLE public.jb_meal_employee_v14 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jb_meal_guest_v14 ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS jb_meal_employee_v14_read ON public.jb_meal_employee_v14;
CREATE POLICY jb_meal_employee_v14_read ON public.jb_meal_employee_v14
FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM public.jb_employees me
    WHERE me.auth_user_id = (SELECT auth.uid()) AND me.active IS TRUE
  )
);
DROP POLICY IF EXISTS jb_meal_guest_v14_read ON public.jb_meal_guest_v14;
CREATE POLICY jb_meal_guest_v14_read ON public.jb_meal_guest_v14
FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM public.jb_employees me
    WHERE me.auth_user_id = (SELECT auth.uid()) AND me.active IS TRUE
  )
);

REVOKE ALL ON public.jb_meal_employee_v14, public.jb_meal_guest_v14
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.jb_meal_employee_v14, public.jb_meal_guest_v14
  TO authenticated;

CREATE OR REPLACE FUNCTION public.jb_meal_assert_edit_v14(
  p_date date, p_meal text, p_department uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_dept uuid;
  v_role text;
  v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_cutoff time := '16:00';
BEGIN
  IF p_date IS NULL OR p_meal NOT IN ('lunch','dinner') OR p_meal IS NULL
     OR p_department IS NULL THEN
    RAISE EXCEPTION '날짜·식사 구분·부서를 확인하세요';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.jb_departments WHERE id=p_department) THEN
    RAISE EXCEPTION '등록되지 않은 부서입니다';
  END IF;
  SELECT department_id, app_role INTO v_dept, v_role
  FROM public.jb_employees
  WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
  IF NOT FOUND OR v_role NOT IN ('owner','manager','staff') THEN
    RAISE EXCEPTION '인증된 재직 직원만 식사를 수정할 수 있습니다'
      USING ERRCODE='42501';
  END IF;
  IF v_role <> 'owner' AND v_dept IS DISTINCT FROM p_department THEN
    RAISE EXCEPTION '본인 소속 부서 직원만 수정할 수 있습니다'
      USING ERRCODE='42501';
  END IF;
  IF v_role = 'staff' AND p_date < v_today THEN
    RAISE EXCEPTION '지난 날짜의 식사는 관리자에게 변경을 요청하세요'
      USING ERRCODE='42501';
  END IF;
  IF v_role = 'staff' AND p_meal='dinner' AND p_date=v_today THEN
    SELECT dinner_deadline::time INTO v_cutoff
    FROM public.jb_meal_settings WHERE id=true;
    IF v_cutoff IS NULL THEN v_cutoff:='16:00'; END IF;
    IF (now() AT TIME ZONE 'Asia/Seoul')::time >= v_cutoff THEN
      RAISE EXCEPTION '저녁 신청 마감시간이 지났습니다'
        USING ERRCODE='42501';
    END IF;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.jb_meal_assert_edit_v14(date,text,uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.jb_meal_save_staff_v14(
 p_date date,p_meal text,p_department uuid,p_items jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_item jsonb;
  v_employee uuid;
  v_eating boolean;
  v_location text;
  v_seen uuid[] := ARRAY[]::uuid[];
  v_count integer := 0;
BEGIN
  PERFORM public.jb_meal_assert_edit_v14(p_date,p_meal,p_department);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items)>200 THEN
    RAISE EXCEPTION '직원 명단 형식 또는 최대 인원을 확인하세요';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    IF jsonb_typeof(v_item) <> 'object'
      OR jsonb_typeof(v_item->'eating') <> 'boolean' THEN
      RAISE EXCEPTION '직원 신청 항목 형식을 확인하세요';
    END IF;
    v_employee := (v_item->>'employee_id')::uuid;
    v_eating := (v_item->>'eating')::boolean;
    v_location := CASE WHEN p_meal='lunch' THEN v_item->>'location' ELSE NULL END;
    IF v_employee=ANY(v_seen) THEN
      RAISE EXCEPTION '동일 직원이 중복 입력되었습니다';
    END IF;
    v_seen:=array_append(v_seen,v_employee);
    IF NOT EXISTS (
      SELECT 1 FROM public.jb_employees
      WHERE id=v_employee AND department_id=p_department AND active IS TRUE
    ) THEN
      RAISE EXCEPTION '해당 부서의 재직 직원이 아닙니다';
    END IF;
    IF v_eating THEN
      IF p_meal='lunch' AND coalesce(v_location,'') NOT IN ('농원','동이','쇼가든') THEN
        RAISE EXCEPTION '점심 식사 장소를 확인하세요';
      END IF;
      INSERT INTO public.jb_meal_employee_v14 (
        meal_date,meal_type,employee_id,department_id,location,updated_by
      ) VALUES (
        p_date,p_meal,v_employee,p_department,v_location,(SELECT auth.uid())
      )
      ON CONFLICT (meal_date,meal_type,employee_id) DO UPDATE
      SET department_id=excluded.department_id,
          location=excluded.location,
          updated_by=excluded.updated_by,
          updated_at=now();
      v_count:=v_count+1;
    ELSE
      DELETE FROM public.jb_meal_employee_v14
      WHERE meal_date=p_date AND meal_type=p_meal AND employee_id=v_employee;
    END IF;
  END LOOP;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.jb_meal_save_staff_v14(date,text,uuid,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_meal_save_staff_v14(date,text,uuid,jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.jb_meal_add_guest_v14(
  p_date date,p_meal text,p_department uuid,p_kind text,
  p_count integer,p_location text,p_note text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM public.jb_meal_assert_edit_v14(p_date,p_meal,p_department);
  IF p_kind NOT IN ('외부 작업자','방문객','협력업체','기타')
     OR p_kind IS NULL OR p_count NOT BETWEEN 1 AND 200
     OR p_count IS NULL OR length(coalesce(p_note,''))>100 THEN
    RAISE EXCEPTION '외부 인원 구분·수량·비고를 확인하세요';
  END IF;
  IF p_meal='lunch' AND coalesce(p_location,'') NOT IN ('농원','동이','쇼가든') THEN
    RAISE EXCEPTION '점심 식사 장소를 확인하세요';
  END IF;
  INSERT INTO public.jb_meal_guest_v14 (
    meal_date,meal_type,department_id,guest_kind,headcount,
    location,note,created_by
  ) VALUES (
    p_date,p_meal,p_department,p_kind,p_count,
    CASE WHEN p_meal='lunch' THEN p_location ELSE NULL END,
    coalesce(p_note,''),(SELECT auth.uid())
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.jb_meal_add_guest_v14(date,text,uuid,text,integer,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_meal_add_guest_v14(date,text,uuid,text,integer,text,text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.jb_meal_remove_guest_v14(p_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_date date;v_meal text;v_dept uuid;
BEGIN
  SELECT meal_date,meal_type,department_id
  INTO v_date,v_meal,v_dept
  FROM public.jb_meal_guest_v14 WHERE id=p_id;
  IF NOT FOUND THEN RAISE EXCEPTION '삭제할 식사 인원이 없습니다'; END IF;
  PERFORM public.jb_meal_assert_edit_v14(v_date,v_meal,v_dept);
  DELETE FROM public.jb_meal_guest_v14 WHERE id=p_id;
END;
$$;
REVOKE ALL ON FUNCTION public.jb_meal_remove_guest_v14(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_meal_remove_guest_v14(uuid)
  TO authenticated;

COMMIT;
