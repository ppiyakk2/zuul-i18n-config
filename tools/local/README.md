# 로컬 테스트 (Mac & Ubuntu 24.04)

`upstream_translation_update` / `propose_translation_update` 잡을 **Zuul 없이** 로컬에서 돌리기 위한 래퍼. 스크립트 편집 → 즉시 실행 → 통과하면 Zuul에서 최종 검증하는 워크플로우를 만든다.

## 빠른 시작

### 1회 설정

```sh
cp tools/local/.env.local.example tools/local/.env.local
$EDITOR tools/local/.env.local        # WEBLATE_TOKEN, GITHUB_TOKEN 입력
tools/local/setup.sh                  # OS 자동 감지 (Mac/Ubuntu)
```

성공 시 다음이 준비된다:
- `~/.venv` — Babel, Sphinx, wlc 등
- `~/scripts/` — `roles/prepare-weblate-client/files/*.{sh,py}` 복사본
- `~/.config/weblate` — Weblate API 자격증명 (Python `requests` 스크립트가 읽음)

### 테스트 브랜치 만들기 (프로젝트별 1회)

production `master` 오염을 막기 위해 fork에 전용 브랜치를 만든다:

```sh
cd ~/work/i18n/test_env/contributor-guide
git fetch origin
git checkout -b localtest/master origin/master
git push -u origin localtest/master
```

### Upstream 실행

```sh
tools/local/run-upstream.sh --project contributor-guide --branch localtest/master
tools/local/run-upstream.sh --project horizon --branch localtest/master    # Ubuntu 권장
```

### Propose 실행

```sh
tools/local/run-propose.sh --project contributor-guide --branch localtest/master
```

PR 브랜치는 `weblate/translations/localtest-master-localtest`(`LOCAL_TEST_BRANCH_SUFFIX` 적용)로 푸시되므로 실 운영 PR과 섞이지 않는다.

### 정리

```sh
tools/local/cleanup.sh --weblate-category localtest-master --project contributor-guide
tools/local/cleanup.sh --github-branch weblate/translations/localtest-master-localtest --project contributor-guide
tools/local/cleanup.sh --all     # 로컬 venv/scripts/.config 전부 제거
```

## 파일 구성

| 경로 | 역할 |
|------|------|
| `setup.sh` | OS 감지 후 provision-mac.sh 또는 provision-ubuntu.sh 디스패치 |
| `run-upstream.sh` | `~/scripts/upstream_translation_update_weblate.sh` 래퍼 |
| `run-propose.sh`  | `~/scripts/propose_translation_update_weblate.sh` 래퍼 |
| `cleanup.sh` | Weblate 카테고리 / GitHub PR 브랜치 / 로컬 상태 정리 |
| `lib/common.sh` | env 로드, 인자 파싱, 안전 가드, upper-constraints fetch |
| `lib/provision-mac.sh` | brew + venv + scripts 복사 (idempotent) |
| `lib/provision-ubuntu.sh` | apt + `ansible-playbook -c local` (role hash 센티넬) |
| `.env.local.example` | 자격증명 템플릿 |

관련 파일:
- `playbooks/local/setup.yaml` — Ubuntu 경로에서 Zuul과 동일한 role 재사용

## 동작 원리

로컬에 Zuul pre-run이 만드는 end-state를 그대로 재현한다:

| Zuul pre-run | 로컬 재현 |
|--------------|-----------|
| `roles/ensure-babel` | Mac: brew + venv pip / Ubuntu: ansible `-c local` |
| `roles/ensure-sphinx` | Mac: venv pip / Ubuntu: ansible `-c local` |
| `roles/prepare-weblate-client` | 양쪽 동일 — `~/.config/weblate`, `~/scripts/*` |
| `roles/prepare-upper-constraints` | `run-*.sh`에서 필요 시 curl 다운로드 |

**래퍼**는 `cd $TARGETS_ROOT/<project>` 후 Zuul과 정확히 동일한 인자로 `~/scripts/{upstream,propose}_translation_update_weblate.sh`를 exec.

## 인자

```
tools/local/run-upstream.sh [--project P] [--branch B] [--target-dir PATH] [--jobname J] [--force]
tools/local/run-propose.sh  [--project P] [--branch B] [--target-dir PATH] [--force]
```

positional도 허용: `run-upstream.sh contributor-guide localtest/master`.

기본값:
- `--branch` 미지정 시 `master`
- `--target-dir` 미지정 시 `$TARGETS_ROOT/<project>`
- `--jobname` 미지정 시 `upstream-translation-update` (horizon은 `-horizon` 자동 추가)

## 안전 가드

`lib/common.sh`가 실행 전에 검증한다:

- target dir이 git repo인지, `origin`이 `github.com/$FORK_OWNER/<project>`와 일치하는지 — openstack/\* 원본은 거부
- branch가 `master` 또는 `stable/*`이고 `LOCAL_TEST_BRANCH_SUFFIX`가 비어 있고 `--force` 미지정이면 거부

`cleanup.sh`도 `master`, `stable-*`, `stable/*` 카테고리 삭제를 거부한다.

## 격리 메커니즘

두 가지가 겹쳐 작동한다:

1. **fork의 `localtest/*` 브랜치** — 업스트림 잡이 Weblate에 `localtest-master` 카테고리를 만들고, 그 아래로만 POT를 올린다.
2. **`LOCAL_TEST_BRANCH_SUFFIX`** — [common_translation_update.sh L274](../../roles/prepare-weblate-client/files/common_translation_update.sh#L274)에서 `pr_branch`에 붙는다. Zuul에는 이 env var가 없어 동작 불변. 로컬에선 `.env.local`의 `-localtest`가 자동 적용되어 PR이 `weblate/translations/<branch>-localtest`로 푸시된다.

## Mac 제약사항

- **horizon Django 추출**: `install_horizon()`이 `xmlsec`/`cryptography` 등 네이티브 의존성을 빌드. Apple Silicon에서 깨질 수 있음. horizon은 Ubuntu 경로 권장.
- **GNU sed**: `common_translation_update.sh`의 `sed -i`는 GNU 문법. provisioner가 `brew install gnu-sed`로 설치하고 PATH를 앞에 놓는다 (`~/.zshrc` 업데이트 후 새 쉘 필요).
- **gettext PATH**: `brew gettext`가 keg-only라 `~/.zshrc`에 PATH export를 추가한다 (sentinel `# zuul-i18n-config:gettext`로 중복 방지).

## Ubuntu 제약사항

- `setup.sh`는 `/etc/os-release`의 `ID=ubuntu`만 허용한다.
- `sudo apt-get`를 사용하므로 passwordless sudo 또는 `sudo` 비밀번호 입력이 필요하다.
- role 파일의 sha256이 sentinel과 다르면 재실행 시 다시 프로비저닝한다 (role 수정이 자동 반영됨).

## iterate 루프

```sh
$EDITOR roles/prepare-weblate-client/files/upstream_translation_update_weblate.sh
tools/local/setup.sh                 # ~/scripts/로 재복사 (idempotent, 수 초)
tools/local/run-upstream.sh --project contributor-guide --branch localtest/master
```

Zuul 왕복(커밋→푸시→스케줄러 재시작→enqueue→로그 확인)을 생략한다.

## Zuul로 이관

로컬 통과 후 기존 워크플로우:
```sh
git add -A && git commit -m "..." && git push
# zuul 스케줄러 재시작, REST API enqueue, 로그 확인 (MEMORY.md 참조)
```
