-- 설치용 / 시험 배포 전 Supabase 운영 DB 적용 필요
-- V1.3 일반 직원도 자기 부서 고정 식사 인원 '추가'만 허용.
-- 기존 jb_meal_regular_manage_v15(대표/관리자 수정·비활성화)는 변경하지 않음.
CREATE OR REPLACE FUNCTION public.jb_meal_regular_add_staff_v13(
 p_department uuid, p_name text, p_place text, p_lunch boolean, p_dinner boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $func$
DECLARE
 v_actor record;
 v_new_id uuid;
BEGIN
 SELECT id, department_id, app_role INTO v_actor
 FROM public.jb_employees
 WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 IF NOT FOUND OR v_actor.app_role NOT IN ('staff','manager','owner') THEN
  RAISE EXCEPTION '활성 직원 계정만 고정 인원을 추가할 수 있습니다' USING ERRCODE='42501';
 END IF;
 IF p_department IS NULL
    OR (v_actor.app_role<>'owner' AND p_department IS DISTINCT FROM v_actor.department_id) THEN
  RAISE EXCEPTION '소속 부서에만 고정 인원을 추가할 수 있습니다' USING ERRCODE='42501';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM public.jb_departments WHERE id=p_department) THEN
  RAISE EXCEPTION '등록되지 않은 부서입니다';
 END IF;
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 80
   OR p_place IS NULL OR p_place NOT IN ('농원','동이','쇼가든')
   OR p_lunch IS NULL OR p_dinner IS NULL THEN
  RAISE EXCEPTION '고정 식사 인원 기본 설정을 확인하세요';
 END IF;
 INSERT INTO public.jb_meal_regular_people_v15(
  department_id,display_name,default_location,default_lunch,default_dinner,active,created_by
 ) VALUES(
  p_department,btrim(p_name),p_place,p_lunch,p_dinner,true,(SELECT auth.uid())
 ) RETURNING id INTO v_new_id;
 RETURN v_new_id;
END;
$func$;
REVOKE ALL ON FUNCTION public.jb_meal_regular_add_staff_v13(uuid,text,text,boolean,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.jb_meal_regular_add_staff_v13(uuid,text,text,boolean,boolean) TO authenticated;
