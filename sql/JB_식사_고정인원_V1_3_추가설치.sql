-- [설치용] JB 업무관리 V1.3 고정 식사 인원
-- 필수 선행: jb_meal_assert_edit_v14 및 식사 V14 테이블 설치
-- 기존 업무·직원·식사 기록 삭제 없음
BEGIN;
CREATE TABLE IF NOT EXISTS public.jb_meal_regular_people_v15 (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 department_id uuid NOT NULL REFERENCES public.jb_departments(id),
 display_name text NOT NULL CHECK(length(btrim(display_name)) BETWEEN 1 AND 80),
 default_location text NOT NULL DEFAULT '농원'
    CHECK(default_location IN ('농원','동이','쇼가든')),
 default_lunch boolean NOT NULL DEFAULT true,
 default_dinner boolean NOT NULL DEFAULT false,
 active boolean NOT NULL DEFAULT true,
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS jb_meal_regular_people_v15_active_name
 ON public.jb_meal_regular_people_v15(department_id,lower(btrim(display_name)))
 WHERE active IS TRUE;
CREATE TABLE IF NOT EXISTS public.jb_meal_regular_orders_v15 (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 meal_date date NOT NULL,
 meal_type text NOT NULL CHECK(meal_type IN ('lunch','dinner')),
 regular_id uuid NOT NULL REFERENCES public.jb_meal_regular_people_v15(id),
 location text,
 updated_by uuid NOT NULL,
 updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT jb_meal_regular_orders_v15_one UNIQUE(meal_date,meal_type,regular_id),
 CONSTRAINT jb_meal_regular_orders_v15_location CHECK (
   (meal_type='lunch' AND location IN ('농원','동이','쇼가든'))
   OR (meal_type='dinner' AND location IS NULL)
 )
);
CREATE INDEX IF NOT EXISTS jb_meal_regular_orders_v15_date
 ON public.jb_meal_regular_orders_v15(meal_date,meal_type);
ALTER TABLE public.jb_meal_regular_people_v15 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jb_meal_regular_orders_v15 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS jb_meal_regular_people_v15_read ON public.jb_meal_regular_people_v15;
CREATE POLICY jb_meal_regular_people_v15_read ON public.jb_meal_regular_people_v15
 FOR SELECT TO authenticated USING(
   EXISTS(SELECT 1 FROM public.jb_employees me
     WHERE me.auth_user_id=(SELECT auth.uid()) AND me.active IS TRUE)
 );
DROP POLICY IF EXISTS jb_meal_regular_orders_v15_read ON public.jb_meal_regular_orders_v15;
CREATE POLICY jb_meal_regular_orders_v15_read ON public.jb_meal_regular_orders_v15
 FOR SELECT TO authenticated USING(
   EXISTS(SELECT 1 FROM public.jb_employees me
     WHERE me.auth_user_id=(SELECT auth.uid()) AND me.active IS TRUE)
 );
REVOKE ALL ON public.jb_meal_regular_people_v15, public.jb_meal_regular_orders_v15
 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.jb_meal_regular_people_v15,public.jb_meal_regular_orders_v15
 TO authenticated;

CREATE OR REPLACE FUNCTION public.jb_meal_regular_manage_v15(
 p_id uuid,p_department uuid,p_name text,p_place text,
 p_lunch boolean,p_dinner boolean,p_active boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_actor record;v_id uuid;v_old_dept uuid;
BEGIN
 SELECT department_id,app_role INTO v_actor
 FROM public.jb_employees
 WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 IF NOT FOUND OR v_actor.app_role NOT IN('owner','manager') THEN
   RAISE EXCEPTION '대표 또는 부서장만 고정 인원을 등록·관리할 수 있습니다'
     USING ERRCODE='42501';
 END IF;
 IF p_department IS NULL OR
  (v_actor.app_role<>'owner' AND p_department IS DISTINCT FROM v_actor.department_id) THEN
   RAISE EXCEPTION '타 부서 고정 인원은 관리할 수 없습니다'
     USING ERRCODE='42501';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.jb_departments WHERE id=p_department) THEN
   RAISE EXCEPTION '등록되지 않은 부서입니다';
 END IF;
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 80
   OR p_place NOT IN ('농원','동이','쇼가든')
   OR p_place IS NULL
   OR p_lunch IS NULL OR p_dinner IS NULL OR p_active IS NULL THEN
   RAISE EXCEPTION '이름·기본 장소·기본 신청 설정을 확인하세요';
 END IF;
 IF p_id IS NULL THEN
   INSERT INTO public.jb_meal_regular_people_v15
    (department_id,display_name,default_location,default_lunch,default_dinner,active,created_by)
   VALUES(p_department,btrim(p_name),p_place,p_lunch,p_dinner,p_active,(SELECT auth.uid()))
   RETURNING id INTO v_id;
 ELSE
   SELECT department_id INTO v_old_dept
   FROM public.jb_meal_regular_people_v15 WHERE id=p_id FOR UPDATE;
   IF NOT FOUND OR v_old_dept IS DISTINCT FROM p_department THEN
     RAISE EXCEPTION '해당 부서 고정 인원 기록이 없습니다'
       USING ERRCODE='42501';
   END IF;
   UPDATE public.jb_meal_regular_people_v15 SET
    display_name=btrim(p_name),default_location=p_place,
    default_lunch=p_lunch,default_dinner=p_dinner,active=p_active,
    updated_at=now()
   WHERE id=p_id RETURNING id INTO v_id;
 END IF;
 RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.jb_meal_regular_manage_v15(
 uuid,uuid,text,text,boolean,boolean,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.jb_meal_regular_manage_v15(
 uuid,uuid,text,text,boolean,boolean,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.jb_meal_regular_save_v15(
 p_date date,p_meal text,p_department uuid,p_items jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_item jsonb;v_regular uuid;v_eating boolean;v_loc text;
 v_seen uuid[]:=ARRAY[]::uuid[];v_count integer:=0;
BEGIN
 PERFORM public.jb_meal_assert_edit_v14(p_date,p_meal,p_department);
 IF p_items IS NULL OR jsonb_typeof(p_items)<>'array'
   OR jsonb_array_length(p_items)>200 THEN
   RAISE EXCEPTION '고정 인원 신청 항목 형식을 확인하세요';
 END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
 LOOP
   IF jsonb_typeof(v_item)<>'object'
     OR jsonb_typeof(v_item->'eating')<>'boolean' THEN
      RAISE EXCEPTION '신청 여부 형식이 올바르지 않습니다';
   END IF;
   v_regular:=(v_item->>'regular_id')::uuid;
   v_eating:=(v_item->>'eating')::boolean;
   v_loc:=CASE WHEN p_meal='lunch' THEN v_item->>'location' ELSE NULL END;
   IF v_regular IS NULL OR v_regular=ANY(v_seen) THEN
     RAISE EXCEPTION '고정 인원 ID 누락 또는 중복입니다';
   END IF;
   v_seen:=array_append(v_seen,v_regular);
   IF NOT EXISTS(SELECT 1 FROM public.jb_meal_regular_people_v15
     WHERE id=v_regular AND department_id=p_department AND active IS TRUE) THEN
     RAISE EXCEPTION '다른 부서이거나 비활성화된 고정 인원입니다'
       USING ERRCODE='42501';
   END IF;
   IF v_eating THEN
     IF p_meal='lunch' AND coalesce(v_loc,'') NOT IN('농원','동이','쇼가든') THEN
       RAISE EXCEPTION '점심 식사 장소를 선택하세요';
     END IF;
     INSERT INTO public.jb_meal_regular_orders_v15
      (meal_date,meal_type,regular_id,location,updated_by)
     VALUES(p_date,p_meal,v_regular,v_loc,(SELECT auth.uid()))
     ON CONFLICT(meal_date,meal_type,regular_id) DO UPDATE SET
      location=excluded.location,updated_by=excluded.updated_by,updated_at=now();
     v_count:=v_count+1;
   ELSE
     DELETE FROM public.jb_meal_regular_orders_v15
      WHERE meal_date=p_date AND meal_type=p_meal AND regular_id=v_regular;
   END IF;
 END LOOP;
 RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.jb_meal_regular_save_v15(date,text,uuid,jsonb)
 FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.jb_meal_regular_save_v15(date,text,uuid,jsonb)
 TO authenticated;
COMMIT;
