# 08. 실전: 번역 파이프라인

지금까지 배운 Zuul의 개념들이 우리 번역 파이프라인에서 어떻게 사용되는지 전체 그림을 그려본다.

## 우리가 만든 것

OpenStack 문서 번역을 자동화하는 두 가지 파이프라인이다.

```
┌─────────────────────────────────────────────────────────┐
│                   번역 자동화 파이프라인                    │
│                                                         │
│  ┌──────────────────┐         ┌──────────────────────┐  │
│  │ Upstream Update   │         │ Downstream Proposal   │  │
│  │ (post pipeline)   │         │ (periodic pipeline)   │  │
│  │                   │         │                       │  │
│  │ 코드 변경 → POT   │         │ Weblate → PO 파일    │  │
│  │ 추출 → Weblate    │         │ → PR 제안             │  │
│  │ 업로드             │         │                       │  │
│  └──────────────────┘         └──────────────────────┘  │
│         ▲                              │                 │
│         │          ┌──────────┐        │                 │
│         └──────────│ Weblate  │←───────┘                 │
│                    │ (번역 서버)│                          │
│                    └──────────┘                          │
│                         ▲                                │
│                         │                                │
│                    번역자가 여기서                          │
│                    번역 작업을 한다                         │
└─────────────────────────────────────────────────────────┘
```

## Upstream Translation Update

**"코드가 바뀌면 번역 원본을 자동 업데이트한다"**

### 트리거

```yaml
# zuul.d/pipelines.yaml
- pipeline:
    name: post
    trigger:
      github:
        - event: push
          ref: ^refs/heads/master$
```

contributor-guide에 코드가 merge되면 자동 실행된다.

### 실행 흐름

```
[GitHub]  master에 push
    ↓ webhook
[Scheduler]  post pipeline → upstream-translation-update job 결정
    ↓
[Executor]  contributor-guide 소스 checkout
    ↓
[base/pre.yaml]  ← hosts: all (노드에서 실행)
    ├── zuul_console 시작 (로그 스트리밍)
    ├── 소스 디렉토리 생성
    └── 소스를 executor → 노드로 rsync
    ↓
[upstream-translation-update/pre.yaml]  ← hosts: all
    ├── ensure-sphinx role (sphinx, reno 설치)
    ├── ensure-babel role (babel, gettext 설치)
    └── prepare-weblate-client role
         ├── wlc 설치
         ├── weblate.ini 생성 (secret에서 URL/토큰 주입)
         └── 스크립트 파일 복사 (sh, py)
    ↓
[upstream-translation-update/run.yaml]  ← hosts: all
    └── upstream_translation_update_weblate.sh 실행
         │
         ├── [step 1] 환경 확인 (WEBLATE_URL, TOKEN)
         ├── [step 2] 브랜치 환경 초기화
         ├── [step 3] Python virtualenv 설정
         ├── [step 4] Weblate 프로젝트 상태 확인
         ├── [step 5] Git proposals 브랜치 설정
         ├── [step 6] Sphinx로 POT 파일 추출
         │    └── extract_messages_doc()
         │         ├── sphinx-build -b gettext
         │         ├── 디렉토리별 POT 분리 (doc-common.pot, doc-users.pot, ...)
         │         └── 나머지 병합 (doc.pot)
         └── [step 7] Weblate에 POT 업로드
              └── upload_pot_weblate.py
                   ├── msgen으로 msgstr 채우기
                   ├── Language:enu 헤더 추가
                   ├── 컴포넌트 존재 확인 (없으면 자동 생성)
                   └── POST /api/translations/.../en_US/file/
    ↓
[base/post-logs.yaml]  ← hosts: localhost (executor에서 실행)
    ├── 로그 파일 복사
    ├── gzip 생성
    ├── zuul-manifest.json 생성
    └── zuul_return으로 log_url 반환
```

### POT 파일이 만들어지는 과정

```
contributor-guide/
  └── doc/source/
       ├── index.rst
       ├── common/
       │   ├── setup.rst
       │   └── git.rst
       └── users/
           └── intro.rst

    ↓ sphinx-build -b gettext

doc/build/gettext/
  ├── index.pot        ← top-level 파일
  ├── common.pot       ← common/ 디렉토리
  └── users.pot        ← users/ 디렉토리

    ↓ 디렉토리 POT → doc-<name>.pot 로 이동, top-level → doc.pot 로 병합

doc/source/locale/
  ├── doc.pot              ← index.rst 등 top-level
  ├── doc-common.pot       ← common/ 디렉토리
  └── doc-users.pot        ← users/ 디렉토리

    ↓ copy_pot → translation-source/

translation-source/master/doc/source/locale/
  ├── doc.pot
  ├── doc-common.pot
  └── doc-users.pot

    ↓ upload_pot_weblate.py (msgen + Language:enu + 업로드)

[Weblate]
  Project: contributor-guide
    Category: master
      Component: doc           ← doc.pot
      Component: doc-common    ← doc-common.pot
      Component: doc-users     ← doc-users.pot
```

## Propose Translation Update

**"번역이 완료되면 자동으로 PR을 올린다"**

### 트리거

```yaml
# zuul.d/pipelines.yaml
- pipeline:
    name: periodic
    trigger:
      timer:
        - time: '0 2 * * *'    # 매일 02:00 UTC
```

### 실행 흐름

```
[Timer]  매일 02:00 UTC
    ↓
[Scheduler]  periodic pipeline → propose-translation-update job
    ↓
[propose-translation-update/run.yaml]
    └── propose_translation_update_weblate.sh
         ├── Weblate API로 컴포넌트 목록 조회
         ├── 각 컴포넌트의 번역 파일(PO) 다운로드
         ├── 프로젝트의 locale/ 디렉토리에 배치
         ├── git commit
         └── PR 생성 (또는 기존 PR 업데이트)
```

## 파일 전체 매핑

### 설정 파일 → 실행 파일

```
zuul.d/projects.yaml
  │ "contributor-guide의 post pipeline에 upstream-translation-update 연결"
  ▼
zuul.d/jobs.yaml
  │ "upstream-translation-update는 base를 상속, 이 playbook과 secret 사용"
  ▼
playbooks/upstream-translation-update/run.yaml
  │ "upstream_translation_update_weblate.sh 실행"
  ▼
roles/prepare-weblate-client/files/upstream_translation_update_weblate.sh
  │ "common_translation_update.sh의 함수들 호출"
  │ "upload_pot_weblate.py로 업로드"
  ▼
roles/prepare-weblate-client/files/common_translation_update.sh
roles/prepare-weblate-client/files/upload_pot_weblate.py
roles/prepare-weblate-client/files/setup_weblate_project.py
```

### 전체 파일 역할 요약

| 파일 | 역할 |
|------|------|
| **설정** | |
| `zuul.d/pipelines.yaml` | 파이프라인 3개 정의 (check, post, periodic) |
| `zuul.d/jobs.yaml` | Job 3개 정의 (base, upstream, propose) |
| `zuul.d/projects.yaml` | contributor-guide에 job 매핑 |
| `zuul.d/secrets.yaml` | Weblate API 인증 정보 (암호화) |
| **Playbook** | |
| `playbooks/base/pre.yaml` | 소스 동기화 + zuul_console (모든 job 공통) |
| `playbooks/base/post-logs.yaml` | 로그 수집 + manifest 생성 (모든 job 공통) |
| `playbooks/upstream-translation-update/pre.yaml` | sphinx, babel, weblate client 설치 |
| `playbooks/upstream-translation-update/run.yaml` | POT 추출 + Weblate 업로드 실행 |
| `playbooks/propose-translation-update/pre.yaml` | sphinx, babel, weblate client 설치 |
| `playbooks/propose-translation-update/run.yaml` | Weblate에서 번역 다운로드 + PR 실행 |
| **Role** | |
| `roles/ensure-sphinx/` | Sphinx 문서 빌드 도구 설치 |
| `roles/ensure-babel/` | Babel i18n 프레임워크 설치 |
| `roles/prepare-weblate-client/` | Weblate CLI + 스크립트 배포 |
| **Script** | |
| `files/upstream_translation_update_weblate.sh` | 메인 업로드 스크립트 (7단계) |
| `files/propose_translation_update_weblate.sh` | 메인 다운로드/PR 스크립트 |
| `files/common_translation_update.sh` | 공통 함수 (POT 추출, PO 관리 등) |
| `files/upload_pot_weblate.py` | POT 전처리 + Weblate API 업로드 |
| `files/setup_weblate_project.py` | Weblate 프로젝트/카테고리/컴포넌트 생성 |
| `files/weblate_utils.py` | Weblate REST API 유틸리티 |
| `files/get-modulename.py` | setup.cfg에서 모듈 이름 추출 |
| `files/common.sh` | Git 관련 공통 함수 |

## Weblate 구조와의 매핑

```
Weblate                          Zuul/Git
───────────────────────────────────────────────
Project                          Git 프로젝트
  = contributor-guide              = ppiyakk2/contributor-guide

Category                         Git 브랜치
  = master                        = refs/heads/master
  = stable-2026-01                = refs/heads/stable/2026.01

Component                        POT 파일 (번역 대상 문서)
  = doc-common                    = doc/source/locale/doc-common.pot
  = doc-users                     = doc/source/locale/doc-users.pot

Language                         PO 파일 (번역 결과)
  = ko_KR                         = doc/source/locale/ko_KR/LC_MESSAGES/doc-common.po
  = ja                            = doc/source/locale/ja/LC_MESSAGES/doc-common.po
```

## 운영 가이드

### 수동 job 트리거

GitHub webhook이 차단된 환경에서는 REST API로 직접 트리거한다.

```bash
# 1. Zuul 인증 토큰 생성
TOKEN=$(docker exec zuul-test-scheduler-1 zuul create-auth-token \
    --auth-config zuul_operator --tenant i18n-test --user admin 2>/dev/null | head -1)

# 2. post pipeline에 enqueue
docker exec zuul-test-scheduler-1 curl -s -X POST \
    "http://web:9000/api/tenant/i18n-test/project/ppiyakk2/contributor-guide/enqueue" \
    -H "Authorization: $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "trigger": "zuul",
        "pipeline": "post",
        "ref": "refs/heads/master",
        "newrev": "<commit-hash>",
        "oldrev": "0000000000000000000000000000000000000000"
    }'

# 3. 빌드 결과 확인
curl -s "http://133.186.247.137:9000/api/tenant/i18n-test/builds?limit=1" | python3 -m json.tool

# 4. 로그 확인
curl -s "http://133.186.247.137:8088/<build-uuid>/job-output.txt"
```

### 설정 변경 후 체크리스트

| 변경 대상 | 필요한 조치 |
|----------|------------|
| `zuul.d/*.yaml` | scheduler + executor 재시작 |
| `playbooks/*.yaml` | push만 하면 됨 (재시작 불필요) |
| `roles/**` | push만 하면 됨 (재시작 불필요) |
| Nodepool 설정 | launcher 재시작 |
| 노드 패키지 | 노드에 직접 SSH 접속하여 설치 |

### 디버깅

1. **빌드 상태 확인**: Web UI (`http://133.186.247.137:9000/`) 또는 API
2. **로그 확인**: 로그 서버 (`http://133.186.247.137:8088/<uuid>/job-output.txt`)
3. **노드 직접 확인**: `ssh ubuntu@133.186.244.143`
4. **Scheduler 로그**: `docker logs zuul-test-scheduler-1`
5. **Executor 로그**: `docker logs zuul-test-executor-1`

### 자주 겪는 문제

| 증상 | 원인 | 해결 |
|------|------|------|
| Job이 시작 안 됨 | webhook 미수신 또는 설정 오류 | REST API로 수동 enqueue |
| "No nodes available" | Nodepool 노드 할당 실패 | launcher 재시작, 노드 상태 확인 |
| 소스 디렉토리 비어있음 | pre.yaml의 synchronize 누락 | base/pre.yaml 확인 |
| 로그에 stdout 안 보임 | zuul_console 누락 | base/pre.yaml에 zuul_console 확인 |
| Secret 접근 오류 | untrusted playbook에서 시도 | config project에 playbook 배치 |
| POT 파일 없음 | copy_pot 경로 문제 | translation-source/ 구조 확인 |
| Weblate API 400 | URL이 http:// | secrets에서 https:// 확인 |
