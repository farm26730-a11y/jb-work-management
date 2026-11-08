# ✅ JB 업무관리 V1.3 — 운영 기준 (MAIN)

> **운영용 기준 브랜치: `main`**  
> 이 저장소의 기본 브랜치입니다. **시험 파일을 운영본으로 착각해 교체하지 마세요.**

## 운영본과 시험본 구분

| 종류 | 브랜치 | 역할 |
| --- | --- | --- |
| ✅ **운영 메인** | **[`main`](https://github.com/farm26730-a11y/jb-work-management/tree/main)** | 실제 운영 기준 소스; Netlify 운영 사이트 연결 |
| 🧪 **최신 시험용 개발본** | **[`development-test`](https://github.com/farm26730-a11y/jb-work-management/tree/development-test)** | 다음 기능 수정·검증 중; **운영 배포 금지** |
| 📁 **개발 이력 보관** | `development/` | 날짜별 SQL·시험 파일, 직접 운영 배포하지 않음 |
| 🗂️ **이전 작업 브랜치** | `feature/*`, `fix/*`, `backup-* ` | 과거/개별 작업 이력, 최신 운영본과 혼동 금지 |

## 실행 파일 위치

현재 운영 소스는 아래 폴더에 있습니다.

`JB_97EBB4B4EBAC_V1_3_A1EAB89DECA0A7EBB7A6ED8C9DEDB88BEC9CB2ECA4B9EDA882EC80/`

- `index.html`: 전체 JB 업무관리 앱
- `sw.js`, `manifest.webmanifest`, 아이콘: PWA·알림 관련 파일
- `netlify.toml`, `netlify/functions/`: Netlify 빌드·푸시 발송 설정

**Netlify 운영 배포 기준**: 브랜치 `main`, Base directory 위 앱 폴더, Publish directory `public`.

## 시험본에만 있는 기능

현재 `development-test`에는 아이콘 위치 조정, 전 부서 고정 식사 인원 추가, 직원 홈의 신규 업무 지시 확인 요청, 댓글 푸시 및 댓글 확인 요청 등 **운영 검증 전 변경 사항**이 포함되어 있습니다. 이 기능들은 이 브랜치에 있다고 해서 자동으로 운영 앱에 반영되는 것이 아닙니다.

## 변경·배포 원칙

1. 수정·검증은 `development-test`에서 진행
2. 기존 V1.3 기능 및 Supabase 권한 확인, 실제 직원 계정 테스트
3. 승인된 수정만 `main`에 병합
4. 운영 Netlify 배포 및 갤럭시 실기기 테스트 후 완료 판단

**주의:** `main`에 커밋하면 연결된 Netlify가 자동 빌드를 시작할 수 있습니다. 앱 파일을 임의로 바꾸거나 운영 배포로 간주하지 마세요. 비밀 키는 GitHub에 올리지 않습니다.

현재 앱 버전 표기는 **V1.3**입니다.
