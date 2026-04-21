# zuul-i18n-config

OpenStack의 Zanata 기반 번역 워크플로우를 **Weblate + GitHub** 로 치환하여 Zuul CI에서 자동화하는 테스트환경 설정 리포지토리.

프로덕션(opendev.org Gerrit + Zanata)의 대응물을 테스트용 NHN Cloud 인프라 위에 재현하고, Weblate REST API와 GitHub API를 사용해 POT 업로드 및 번역 PR 생성을 처리한다.

## 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [리포지토리 구조](#2-리포지토리-구조)
3. [주요 스크립트 설명](#3-주요-스크립트-설명)
4. [테스트 Zuul 환경 구축 가이드](#4-테스트-zuul-환경-구축-가이드)
5. [로컬에서 테스트하는 방법](#5-로컬에서-테스트하는-방법)
6. [Zuul 전체 파이프라인 동작 원리](#6-zuul-전체-파이프라인-동작-원리)
7. [테스트환경 전용 설정](#7-테스트환경-전용-설정-프로덕션-전환-시-교체-필요)
8. [주요 문서 / 참고 자료](#8-주요-문서--참고-자료)

---

## 1. 프로젝트 개요

### 목적

OpenStack 공식 번역 파이프라인의 각 단계를 Weblate 기반으로 재구성해 아래 두 잡을 Zuul에서 자동 실행한다.

- **upstream-translation-update** — 원본 레포에서 POT 파일을 추출해 Weblate에 업로드. `post` 파이프라인 (`master` / `stable/*` push) 에서 트리거.
- **propose-translation-update** — Weblate에서 번역(PO)을 내려받아 PR을 생성. `periodic` 파이프라인 (매일 UTC 02:00) 에서 트리거.

대상 프로젝트는 [`<your-org>/contributor-guide`](https://github.com/<your-org>/contributor-guide)와 [`<your-org>/horizon`](https://github.com/<your-org>/horizon)의 개인 fork이며, 프로덕션 `openstack/*` 레포의 대체이다.

### OpenStack 공식 구조와의 관계

원본 Zanata 파이프라인 구현은 아래 리포에 흩어져 있다.

| 원본 레포 | 우리 구현 |
|-----------|-----------|
| `openstack/project-config` | [`playbooks/`](playbooks/) (pre/run 분리) |
| `openstack/openstack-zuul-jobs` | [`roles/prepare-weblate-client/`](roles/prepare-weblate-client/) 기반 |
| `zuul/zuul-jobs` | [`roles/ensure-babel`](roles/ensure-babel/) / [`roles/ensure-sphinx`](roles/ensure-sphinx/) 재구현 |
| Gerrit git-review | GitHub REST API (`push_to_github()`) |
| Zanata 클라이언트 | wlc + Weblate REST (Python `requests`) |

[`docs/manual/`](docs/manual/) 에 Zuul 전반에 대한 학습용 교재가 포함되어 있다.

### 기술 스택

- **CI**: Zuul 9.x (Docker Compose로 NHN 테스트 서버에 배포)
- **번역 플랫폼**: Weblate 5.15.1 (자체 호스팅)
- **언어 파일 형식**: `po-mono` (source=`en_US`, pseudo-locale=`enu`)
- **POT 추출**: Babel, Sphinx, sphinx-intl
- **PR 자동화**: GitHub REST API + Personal Access Token

---

## 2. 리포지토리 구조

```
zuul-i18n-config/
├── zuul.d/                           # Zuul config (pipelines, jobs, projects, secrets)
├── playbooks/
│   ├── base/                         # pre/post-logs — workspace sync, zuul_console
│   ├── upstream-translation-update/  # POT 추출 → Weblate 업로드
│   ├── upstream-translation-update-horizon/  # horizon 전용 (upper-constraints 포함)
│   ├── propose-translation-update/   # PO 다운로드 → PR 생성
│   └── local/                        # 로컬 테스트용 ansible-playbook -c local
├── roles/
│   ├── ensure-babel/                 # gettext + Babel/pbr/lxml/requests
│   ├── ensure-sphinx/                # sphinx + reno + sphinx-intl + openstackdocstheme
│   ├── prepare-weblate-client/       # wlc install, ~/.config/weblate, 스크립트 복사
│   └── prepare-upper-constraints/    # opendev upper-constraints.txt 다운로드
├── tools/
│   ├── import_po_to_weblate.py       # 기존 PO 일괄 임포트 유틸
│   └── local/                        # 로컬 테스트 래퍼 (아래 5절)
└── docs/                             # 가이드 문서 + 교재 (docs/manual/)
```

---

## 3. 주요 스크립트 설명

모든 bash/Python 번역 스크립트는 [`roles/prepare-weblate-client/files/`](roles/prepare-weblate-client/files/) 에 있고 Zuul pre-run에서 원격 노드의 `~/scripts/` 로 복사된다. 로컬 테스트에서도 같은 위치로 복사된다.

### 진입점 스크립트

#### `upstream_translation_update_weblate.sh`

```
upstream_translation_update_weblate.sh PROJECT JOBNAME BRANCHNAME [HORIZON_DIR]
```

총 7단계로 실행된다.

1. Weblate 환경 검증 (URL/토큰 존재, 프로젝트 잠금 여부)
2. 브랜치 초기화 (`TOX_CONSTRAINTS_FILE`, `GIT_BRANCH` 설정)
3. venv 활성화
4. Weblate 프로젝트 상태 확인 (lock/unavailable 시 정상 종료)
5. git 설정
6. 프로젝트 타입별 메시지 추출
   - Manuals: `tox -e generatepot-*` 또는 Sphinx gettext
   - Python: `pybabel extract` (모듈별)
   - Django: `install_horizon` 후 `pybabel extract` Django keyword
   - ReactJS: npm 기반
   - Release notes: `sphinx-build -b gettext`
7. POT 업로드 (`upload_pot_weblate.py`) — 컴포넌트/카테고리 자동 생성

#### `propose_translation_update_weblate.sh`

```
propose_translation_update_weblate.sh PROJECT [BRANCH]
```

1. 브랜치 초기화
2. venv 활성화
3. git 설정 (`git checkout -B proposals`)
4. Weblate에서 PO 다운로드 (`download_translations_weblate.py`)
5. PO 파일 정리 (40% 번역률 미만 제거, 로그 레벨 PO 제거, 릴리즈 노트 품질 게이트)
6. 커밋 필터링 (빈 파일, 유효하지 않은 PO, 메타데이터만 변경된 diff 제거)
7. 패치 전송 (commit + push to GitHub + PR 생성/업데이트)

### 공통/라이브러리

- **`common_translation_update.sh`** — 공유 함수 라이브러리. `init_branch`, `setup_venv`, `extract_messages_{python,django,doc,releasenotes}`, `install_horizon`, `cleanup_{po,pot,log}_files`, `compress_po_files`, `filter_commits`, `send_patch`, `push_to_github`, `copy_pot` 등.
- **`common.sh`** — GitHub 어댑터. Gerrit의 `git-review` 대신 no-op 및 GitHub 특화 함수 제공.

### Python 유틸리티

- **`setup_weblate_project.py`** — REST API로 project/category/component 생성. `po-mono` 포맷, `source_language=en_US`, docfile 업로드 방식. 컴포넌트 존재 여부는 category URL 매칭으로 판별.
- **`upload_pot_weblate.py`** — POT 파일을 전처리(`msgen` + `Language: enu` 헤더)한 뒤 Weblate API로 업로드.
- **`download_translations_weblate.py`** — 컴포넌트별 PO를 다운로드해 `locale/*/LC_MESSAGES/*.po` 경로로 배치 (upload의 역매핑 적용).
- **`check_weblate_project.py`** — 프로젝트 잠금/가용성 체크. `OK`, `LOCKED`, `UNAVAILABLE:<code>` 반환.
- **`weblate_utils.py`** — `wlc` ini 파서 (`[weblate]`, `[keys]` 양쪽 지원).
- **`get-modulename.py`** — `setup.cfg` / `pyproject.toml` 에서 모듈명 추출.

> [!NOTE]
> Weblate REST 호출은 **전부 Python `requests`** 로 수행한다. `~/.curlrc` 사용은 과거에 리모트 노드에서 HTTP 400/헤더 중복 문제를 일으켜 제거했다. GitHub API는 `curl -q -H "Authorization: token ..."` 로 명시 호출한다.

### 기타 도구

- **[`tools/import_po_to_weblate.py`](tools/import_po_to_weblate.py)** — Weblate 설치 이전에 존재하던 기존 PO 파일들을 컴포넌트에 일괄 임포트. `method=replace` 로 호출해야 정상 반영된다 (`translate` 는 accepted:0).

---

## 4. 테스트 Zuul 환경 구축 가이드

### 인프라 개요

| 역할 | IP | 비고 |
|------|-----|------|
| Zuul 서버 | `<ZUUL_HOST_IP>` | Docker Compose (scheduler/executor/web) |
| 리모트 노드 | `<WORKER_HOST_IP>` | Ubuntu 24.04, label `ubuntu-noble` |
| Weblate | `weblate.example.com` | Self-hosted, v5.15.1, HTTPS 필수 |
| 로그 서버 | `<ZUUL_HOST_IP>:8088` | |
| Web UI | `<ZUUL_HOST_IP>:9000` | Tenant `i18n-test` |

- Zuul SSH: `ssh -i ~/.ssh/your-zuul-key.pem ubuntu@<ZUUL_HOST_IP>`
- 리모트 노드 SSH: `ssh -i ~/.ssh/your-worker-key.pem ubuntu@<WORKER_HOST_IP>`
- Docker 컨테이너: `zuul-test-{scheduler,executor,web,launcher}-1`
- 타임존: KST (`TZ=Asia/Seoul` in docker-compose)

### Zuul 컨테이너 구성

Zuul 서버에서는 단일 VM 위에 Docker Compose로 Zuul 9.x를 올린다. 주요 컨테이너:

- `zuul-test-scheduler-1` — 스케줄러. 파이프라인 관리, enqueue 대상.
- `zuul-test-executor-1` — Ansible playbook 실행. `roles/` 와 `playbooks/` 를 항상 GitHub에서 최신으로 가져온다.
- `zuul-test-web-1` — REST API + Web UI (포트 9000).
- `zuul-test-launcher-1` — Nodepool static provider. 리모트 노드 할당.

zuul.conf에서 GitHub 연결은 `exclude_forks=false` 로 fork 레포도 추적할 수 있게 한다. 단, 새 레포를 추가할 때는 ZK 캐시를 비워야 반영된다.

### config project / untrusted project

- **Config project** (load-branch `main`): `<your-org>/zuul-i18n-config`
- **Untrusted projects** (trigger 대상): `<your-org>/contributor-guide`, `<your-org>/horizon` — `include: []` 로 설정해 대상 레포 안의 `.zuul.yaml` 을 무시한다.

### 리모트 노드 프로비저닝

프로덕션 OpenStack과 동일하게 Ubuntu 24.04 노드에서 잡을 실행한다. Debian 12 기반 executor 컨테이너에서 직접 실행하면 apt/locale 이슈로 `sphinx-build` 가 실패하기 때문이다.

```bash
# 시스템 패키지
sudo apt-get install -y \
    python3-virtualenv python3-pip python3-venv \
    gettext locales python3-sphinx python3-babel \
    python3-requests python3-openstackdocstheme
sudo locale-gen en_US.UTF-8

# PEP 668 대응 (Ubuntu 24.04가 시스템 Python에 pip install 차단)
mkdir -p ~/.config/pip
cat > ~/.config/pip/pip.conf << 'EOF'
[global]
break-system-packages = true
EOF
```

자세한 단계는 [`docs/remote-node-setup.md`](docs/remote-node-setup.md) 참조.

### Nodepool 설정

Nodepool static provider를 사용한다. `/home/ubuntu/zuul-test/etc/nodepool/nodepool.yaml` 에 `ubuntu-noble` 라벨을 정의한다.

```yaml
providers:
  - name: static
    driver: static
    pools:
      - name: main
        nodes:
          - name: <WORKER_INTERNAL_IP>
            labels: ubuntu-noble
            username: ubuntu
            host-key-checking: false
```

SSH 키(`nodepool_rsa.pub`)를 노드의 `authorized_keys` 에 설치. 변경 시 `zuul-test-launcher-1` 재시작 필요.

### Weblate 설정

- HTTPS 필수 (nginx가 http:// 거부)
- `wlc` 인증은 `~/.config/weblate` (ini 포맷)으로 처리
- 컴포넌트는 `po-mono` + `source_language=en_US` + docfile 업로드
- POT를 Weblate에 올릴 때는 `msgen` + `Language: enu` 헤더 추가 필수 (내장 `en` pseudo-language가 `en_us` alias와 충돌하는 문제 회피)
- 컴포넌트 슬러그는 `[a-zA-Z0-9_-]` 만 허용 → `stable/2026.01` → `stable-2026-01` 로 정규화

자세한 내용은 [`docs/weblate-setup-guide.md`](docs/weblate-setup-guide.md) 참조.

### Zuul secrets

[`zuul.d/secrets.yaml`](zuul.d/secrets.yaml) 에 다음 두 secret이 암호화되어 있다.

- `weblate_api_credentials` — Weblate API URL + 토큰
- `github_credentials` — GitHub PAT (PR push/create용, propose 잡에서 사용)

Secret을 사용하는 playbook은 Zuul의 *trusted* 로 취급되어 리모트 노드의 task 출력이 숨겨지는 특성이 있다. 디버깅 시엔 리모트에 SSH로 직접 접속해 스크립트를 실행한다.

---

## 5. 로컬에서 테스트하는 방법

[`tools/local/`](tools/local/) 아래의 래퍼를 사용하면 Zuul 왕복(커밋→푸시→스케줄러 재시작→enqueue→로그 확인) 없이 수초 단위로 iterate 할 수 있다.

### 전제

- `<your-org>/contributor-guide` 또는 `<your-org>/horizon` fork의 체크아웃이 `$TARGETS_ROOT/<project>` 에 존재해야 한다 (기본 `~/work/i18n/test_env`).
- Weblate는 **실제 서비스** `https://weblate.example.com` 를 사용한다. 테스트 브랜치(`localtest/*`)로 격리한다.
- 지원 OS: macOS, Ubuntu 24.04.

### 1회 설정

```bash
cp tools/local/.env.local.example tools/local/.env.local
$EDITOR tools/local/.env.local       # WEBLATE_TOKEN, GITHUB_TOKEN 입력
tools/local/setup.sh                 # uname으로 Mac/Ubuntu 자동 감지
```

`setup.sh` 실행 후 생성되는 상태:

- `~/.venv` — Babel, Sphinx, reno, sphinx-intl, openstackdocstheme, wlc
- `~/scripts/` — `roles/prepare-weblate-client/files/*.{sh,py}` 사본
- `~/.config/weblate` — Weblate API 자격증명 (Python `requests` 가 읽음)

Mac 경로는 `brew` + `pyenv` 기반이고, Ubuntu 경로는 동일한 Ansible role을 `ansible-playbook -c local` 로 재사용한다 (Zuul과 드리프트 0).

### 테스트 브랜치 생성 (프로젝트별 1회)

production 브랜치 오염을 막기 위해 fork에 전용 브랜치를 만든다.

```bash
cd ~/work/i18n/test_env/contributor-guide
git fetch origin
git checkout -b localtest/master origin/master
git push -u origin localtest/master
```

### Upstream 실행

```bash
tools/local/run-upstream.sh --project contributor-guide --branch localtest/master
```

결과:
- POT 추출 → Weblate의 `contributor-guide/localtest-master` 카테고리로 업로드
- 컴포넌트(`doc-*`) 자동 생성

### Propose 실행

```bash
tools/local/run-propose.sh --project contributor-guide --branch localtest/master
```

결과:
- Weblate에서 PO 다운로드 → `doc/source/locale/` 배치 → commit
- `LOCAL_TEST_BRANCH_SUFFIX=-localtest` 가 적용되어 `weblate/translations/localtest/master-localtest` 브랜치로 push (production `weblate/translations/master` 와 격리)
- PR 생성/업데이트

### 격리 매커니즘

두 장치가 겹쳐 동작한다.

1. `localtest/*` 테스트 브랜치 → Weblate 카테고리 이름이 `localtest-*`
2. `LOCAL_TEST_BRANCH_SUFFIX` → PR 브랜치 이름에 suffix 부착. `common_translation_update.sh` 에서 환경변수로 제어. Zuul에서는 이 변수가 비어 있어 동작 불변.

### Cleanup

```bash
# Weblate 카테고리 삭제 (localtest-* 만 허용, master/stable-*는 거부)
tools/local/cleanup.sh --weblate-category localtest-master \
                       --project contributor-guide

# fork의 PR 브랜치 삭제 + 열린 PR 닫기
tools/local/cleanup.sh --github-branch weblate/translations/localtest/master-localtest \
                       --project contributor-guide

# 로컬 상태 전부 제거 (~/.venv, ~/scripts, ~/.config/weblate)
tools/local/cleanup.sh --all
```

### 주요 제약사항

- **Mac**: `install_horizon()` 이 `cryptography`, `xmlsec` 등 네이티브 의존성을 빌드. Apple Silicon에서 자주 깨진다 → horizon은 Ubuntu 경로 권장.
- **Mac**: `common_translation_update.sh` 의 `sed -i` 가 GNU 문법이라 BSD sed와 호환되지 않는다. Provisioner가 `gnu-sed` 를 설치하고 `lib/common.sh` 가 실행 시 PATH 앞에 붙인다.
- **Ubuntu**: passwordless sudo 또는 비밀번호 입력 필요 (`apt-get`).

전체 사용법 및 트러블슈팅은 [`tools/local/README.md`](tools/local/README.md) 참조.

---

## 6. Zuul 전체 파이프라인 동작 원리

### 파이프라인 정의

[`zuul.d/pipelines.yaml`](zuul.d/pipelines.yaml) 에 3개 파이프라인이 정의되어 있다.

| 파이프라인 | 트리거 | 설명 |
|------------|--------|------|
| `check` | GitHub PR open/changed | `noop` 잡만 실행 (status만 표시) |
| `post` | push to `master`/`stable/*` | upstream-translation-update 실행 |
| `periodic` | 매일 UTC 02:00 (timer) | propose-translation-update 실행 |

`check` 파이프라인은 PR 머지 전 smoke test 용도이다. 현재는 설정만 되어 있고 실제 번역 관련 잡은 실행하지 않는다.

### 프로젝트-잡 매핑

[`zuul.d/projects.yaml`](zuul.d/projects.yaml):

- `<your-org>/contributor-guide` → post: upstream-translation-update, periodic: propose-translation-update
- `<your-org>/horizon` → post: upstream-translation-update-horizon, periodic: propose-translation-update-horizon

### 잡 실행 흐름 (OpenDev pre-run 패턴)

```
┌──────────────────────────┐
│ Zuul scheduler           │  pipeline trigger로 enqueue
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ Zuul executor            │
│  1) 레포 체크아웃         │  config + source repos
│  2) zuul-jobs role 로드   │
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ pre-run (executor 위)    │
│  playbooks/base/pre.yaml │  워크스페이스 rsync + zuul_console
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ pre-run (원격 노드 위)   │
│  ensure-sphinx           │  venv에 Sphinx 스택
│  ensure-babel            │  gettext + Babel/lxml/requests
│  prepare-weblate-client  │  wlc + ~/.config/weblate + ~/scripts/
│  [prepare-upper-         │  horizon upstream / 모든 propose
│   constraints]           │
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ run (원격 노드 위)       │
│  upstream/propose        │  7단계 번역 스크립트
│  *_weblate.sh            │
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ post-run (executor 위)   │
│  post-logs.yaml          │  로그 수집 + log server 업로드
└──────────────────────────┘
```

- Executor는 매 잡마다 config + playbook/role의 최신 main 브랜치를 가져온다. **playbooks/roles 변경은 scheduler 재시작 불필요**.
- `zuul.d/` (pipelines/jobs/projects/secrets) 변경은 scheduler/executor 재시작이 **필요**.
- [`playbooks/base/pre.yaml`](playbooks/base/pre.yaml) 에서 executor에 체크아웃된 소스를 원격 노드로 `synchronize` (rsync) 해야 하며 (Zuul은 자동으로 동기화하지 않음), 동시에 `zuul_console` 데몬을 원격에서 띄워야 실시간 로그가 보인다.
- `post-logs.yaml` 은 `hosts: localhost` (executor) 에서 실행된다. 로그는 executor에 쌓이기 때문.

### 수동 트리거 (REST API)

GitHub webhook이 보안 그룹 정책으로 차단되어 있어, 테스트 트리거는 REST API로 한다.

```bash
# 1. (zuul.d/ 변경 시에만) scheduler + executor 재시작
ssh -i ~/.ssh/your-zuul-key.pem ubuntu@<ZUUL_HOST_IP> \
  "docker restart zuul-test-scheduler-1 zuul-test-executor-1"

# 2. Zuul readiness 대기
ssh -i ~/.ssh/your-zuul-key.pem ubuntu@<ZUUL_HOST_IP> \
  "until curl -sf http://localhost:9000/api/tenants > /dev/null; do sleep 3; done"

# 3. 인증 토큰 생성 + enqueue
ssh -i ~/.ssh/your-zuul-key.pem ubuntu@<ZUUL_HOST_IP> '
  TOKEN=$(docker exec zuul-test-scheduler-1 zuul create-auth-token \
            --auth-config zuul_operator --tenant i18n-test --user admin \
            2>/dev/null | head -1)
  docker exec zuul-test-scheduler-1 curl -s -X POST \
    "http://web:9000/api/tenant/i18n-test/project/<your-org>/contributor-guide/enqueue" \
    -H "Authorization: $TOKEN" -H "Content-Type: application/json" \
    -d "{\"trigger\":\"zuul\",\"pipeline\":\"post\",\"ref\":\"refs/heads/master\",
         \"newrev\":\"<COMMIT_HASH>\",
         \"oldrev\":\"0000000000000000000000000000000000000000\"}"
'

# 4. 빌드 결과 확인
curl -s "http://<ZUUL_HOST_IP>:9000/api/tenant/i18n-test/builds?project=<your-org>/contributor-guide&pipeline=post&limit=1"

# 5. 로그 조회
curl -s "http://<ZUUL_HOST_IP>:8088/<build-uuid>/job-output.txt"
```

상세 API 및 디버깅 팁은 [`docs/`](docs/) 하위 문서 참조.

---

## 7. 테스트환경 전용 설정 (프로덕션 전환 시 교체 필요)

프로덕션(OpenStack `openstack/*` + Gerrit + Zanata)으로 전환할 때 교체해야 할 항목.

### GitHub 전용 (프로덕션은 Gerrit)

- [`zuul.d/secrets.yaml`](zuul.d/secrets.yaml) `github_credentials`
- `common_translation_update.sh` `push_to_github()`, `check_already_approved()`
- `common.sh` (Gerrit `git-review` no-op 대체물)
- [`zuul.d/pipelines.yaml`](zuul.d/pipelines.yaml) GitHub trigger/reporter → Gerrit
- [`zuul.d/jobs.yaml`](zuul.d/jobs.yaml) propose 잡의 `github_credentials` 바인딩

### 개인 fork (프로덕션은 `openstack/*`)

- `<your-org>/contributor-guide` → `openstack/contributor-guide`
- `<your-org>/horizon` → `openstack/horizon`
- `<your-org>/zuul-i18n-config` → `openstack/openstack-zuul-jobs` 또는 `project-config`

### 테스트 서버 인프라

- Zuul 서버 IP `<ZUUL_HOST_IP>` (post-logs.yaml, docs 곳곳)
- 로그 서버 `<ZUUL_HOST_IP>:8088`
- 리모트 노드 `<WORKER_HOST_IP>`
- Docker 컨테이너명 `zuul-test-*`
- Tenant `i18n-test`
- SSH 키 `~/.ssh/your-zuul-key.pem`

### 테스트 Weblate

- URL `https://weblate.example.com` → 프로덕션 Weblate
- `weblate_api_credentials` secret 값

### 전환 절차

1. `git tag test-env-backup-YYYY-MM-DD` 로 현 상태 백업
2. 프로덕션 접속 정보 수집 (Gerrit, Weblate, 로그서버, tenant, 레포 목록)
3. 위 항목 치환
4. GitHub 전용 코드 제거/교체

---

## 8. 주요 문서 / 참고 자료

### 내부 문서

- [`docs/manual/`](docs/manual/) — Zuul 8장 교재 (개요, 아키텍처, 설정, 잡 실행, playbook, nodepool, secrets, 번역 파이프라인)
- [`docs/remote-node-setup.md`](docs/remote-node-setup.md) — 리모트 노드 프로비저닝 가이드
- [`docs/weblate-setup-guide.md`](docs/weblate-setup-guide.md) — Weblate 프로젝트/컴포넌트 생성 및 POT 업로드 규칙
- [`docs/propose-cleanup-pipeline.md`](docs/propose-cleanup-pipeline.md) — propose 잡의 cleanup/compress 단계 설명
- [`docs/job-execution-flow.md`](docs/job-execution-flow.md) — 잡 실행 플로우 상세
- [`docs/zuul-web-log-viewer.md`](docs/zuul-web-log-viewer.md) — 로그 서버 및 Web UI 사용법
- [`tools/local/README.md`](tools/local/README.md) — 로컬 테스트 세부 사용법

### 외부 참조

- OpenStack 원본 번역 파이프라인: <https://opendev.org/openstack/project-config> `playbooks/translation/`
- Zanata 클라이언트 role: <https://opendev.org/openstack/openstack-zuul-jobs> `roles/prepare-zanata-client/`
- 표준 ensure-* role: <https://opendev.org/zuul/zuul-jobs> `roles/ensure-{babel,sphinx,tox}`
- Weblate REST API: <https://docs.weblate.org/en/latest/api.html>

---

## 라이선스

Apache License 2.0 (원본 OpenStack 스크립트 라이선스 계승)
