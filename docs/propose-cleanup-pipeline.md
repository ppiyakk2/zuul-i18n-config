# propose job의 cleanup/compress 파이프라인

## 배경

`propose-translation-update` job은 Weblate에서 PO 파일을 다운로드해 원본
repo에 PR을 올리는 역할을 한다. 초기 구현은 단순히 다운로드 후 `git add`만
수행해서 다음 문제가 있었다.

- 번역률이 낮은 언어(예: 5%만 번역됨)도 그대로 커밋됨
- PO 파일 안의 `#: file.py:123` 소스 위치 주석이 diff를 지저분하게 만듦
- Weblate 컴포넌트별로 `.pot` 파일이 git에 섞임 (우리는 POT을 커밋하지 않는 정책)
- 릴리즈노트의 언어별 번역 품질을 검사할 장치가 없음

OpenStack의 원본 Zanata 워크플로우(openstack/openstack-zuul-jobs의
`propose_translation_update.sh`)는 **프로젝트 타입별로 분기해서 모듈마다
cleanup/compress를 적용**하는 패턴을 쓴다. 이 구조를 우리 Weblate 버전에도
이식했다.

## 구조

`roles/prepare-weblate-client/files/propose_translation_update_weblate.sh`는
7단계로 구성된다.

```
[step 1/7] init_branch                 # TOX_CONSTRAINTS_FILE 등 환경변수
[step 2/7] setup_venv                  # ~/.venv 활성화 (sphinx, reno)
[step 3/7] setup_git                   # git checkout -B proposals
[step 4/7] download_translations       # Weblate API → PO 파일
[step 5/7] 프로젝트 타입별 cleanup       # case dispatch
[step 6/7] setup_review + filter_commits
[step 7/7] send_patch                  # push + PR 생성
```

step 5의 case dispatch는 `upstream_translation_update_weblate.sh`의 분기와
동일한 모양이다.

```bash
case "$PROJECT" in
    api-site|openstack-manuals|security-doc|contributor-guide)
        propose_manuals
        ;;
    training-guides|i18n)
        cleanup_module "doc"
        git add -A doc/source/locale
        ;;
    *)  # horizon 등
        propose_python_django_all
        ;;
esac
```

## cleanup_module 헬퍼

`common_translation_update.sh`에 추가된 헬퍼로, 모듈 하나에 대해 세 단계를
순서대로 실행한다.

```bash
function cleanup_module {
    local modulename=$1
    cleanup_po_files "$modulename"   # 번역률 < 40% PO를 git rm
    cleanup_pot_files "$modulename"  # POT 파일 제거 (커밋 안 함)
    compress_po_files "$modulename"  # #: 주석 제거 + 정렬
}
```

순서가 중요하다. `compress_po_files`는 `msgattrib --translated`로 미번역
msgid를 지우는데, 그 전에 `cleanup_po_files`가 `check_po_file`로 번역률을
세어야 한다. compress 먼저 돌리면 모든 파일이 100% 번역된 것처럼 보여서
번역률 필터가 무의미해진다.

## 프로젝트 타입별 처리

### 문서 프로젝트 (`propose_manuals`)

`contributor-guide`, `openstack-manuals`, `api-site`, `security-doc`이
해당된다. `init_manuals`로 `DocFolder`를 정한 뒤(대부분 `doc`), doc 모듈
하나에 대해 `cleanup_module`을 호출하고 `${DocFolder}/*/{,source/}locale`을
git에 stage한다.

### Python/Django 프로젝트 (`propose_python_django_all`)

horizon이 대표적이다. 세 가지 블록을 순서대로 처리한다.

1. **모듈별 cleanup**: `get_modulename`으로 `setup.cfg`의
   `[openstack_translations]` 섹션에서 python/django 모듈 목록을 얻어
   각 모듈의 `locale/`에 `cleanup_module` 호출. master 브랜치에서는
   `cleanup_log_files`도 추가로 실행(과거 log level PO 파일 정리).

2. **install_horizon**: django 모듈이 있고 master + releasenotes가
   존재하면 `pip install -c upper-constraints.txt -r requirements.txt`로
   horizon 패키지를 venv에 설치한다. `releasenotes/source/conf.py`가
   `import horizon`을 하기 때문에 필요하다.

3. **릴리즈노트 품질 게이트 (`propose_releasenotes`)**: master 브랜치 +
   `releasenotes/source/conf.py` 존재 시에만 실행.
   - `extract_messages_releasenotes 1` (workdir 유지)로 릴리즈별 POT을
     `releasenotes/work/`에 추출
   - 언어별 `releasenotes.po`에 대해
     `check_releasenotes_per_language`로 **릴리즈별 최대 번역률** 기준
     판정 (≥75%면 신규 추가 허용, <40%면 `git rm`)
   - workdir 정리 후 `cleanup_pot_files` + `compress_po_files`

### 단순 케이스 (`training-guides`, `i18n`)

doc 모듈만 있어서 dispatch에서 인라인으로 `cleanup_module "doc"` + git add.

## 주요 재활용 함수

대부분의 cleanup 함수는 이미 `common_translation_update.sh`에 있었고 다만
propose 스크립트에서 호출되지 않고 있었다(원본 OpenStack의 Zanata 흐름
잔재). 아래는 이번에 활용하게 된 함수들이다.

| 함수 | 역할 |
|------|------|
| `cleanup_po_files` | 번역률 < 40% PO 제거 (`msgfmt --statistics` 기반) |
| `cleanup_pot_files` | 디렉토리 내 모든 `.pot` 제거 (git rm 포함) |
| `compress_po_files` | `msgattrib --translated --no-location --sort-output` 적용 |
| `cleanup_log_files` | `*-log-{info,warning,error,critical}.po` 제거 (legacy) |
| `check_po_file` | `$RATIO` 전역에 번역률 설정 |
| `check_releasenotes_per_language` | 릴리즈별 POT에 msgmerge 후 최대 번역률로 판정 |
| `get_modulename` | `setup.cfg`의 python/django 모듈 목록 반환 |
| `install_horizon` | horizon 패키지를 venv에 pip install |
| `extract_messages_releasenotes` | reno+sphinx로 릴리즈노트 POT 추출 |

## playbook 변경

`playbooks/propose-translation-update/pre.yaml`에
`prepare-upper-constraints` role을 추가했다. `install_horizon`이
`upper-constraints.txt`를 요구하기 때문이다. 다른 프로젝트에서도
upper-constraints 파일이 다운로드되지만 사용하지 않고 무시되므로 부작용은
없다.

OpenDev는 모든 프로젝트가 하나의 공통 pre.yaml을 쓰므로 horizon 전용
pre.yaml을 따로 만들지 않는다. 우리도 그 패턴을 따른다.

## 검증

두 프로젝트에서 end-to-end 테스트 성공.

- **contributor-guide** (manuals type)
  - Build: `b19572a4fee9477989d8269bc28e7cd2`
  - `Type: manuals project` dispatch 확인
  - `cleanup_pot_files`가 `doc/source/locale/` 하위 8개 POT 제거
  - `filter_commits`가 실질적 변경 없음을 감지 → PR 생성 없이 정상 종료

- **horizon** (python/django type)
  - Build: `54bb6ec85674424991d00f7dda05a75d`
  - `Type: python/django` dispatch 확인
  - Django 모듈 3개(horizon, openstack_dashboard, openstack_auth) 순회
  - `install_horizon` + `extract_messages_releasenotes` 실행 (reno가 모든
    stable 브랜치 스캔)
  - `send_patch` → **PR #1 생성**: 676 insertions / 550 deletions
    (compress_po_files가 PO 파일을 rewrite한 결과)

## 커밋 이력

- `5f41f1d` — Add project-type dispatch and cleanup to propose script
- `1365ed6` — Add prepare-upper-constraints to shared propose pre.yaml
  (중간에 horizon 전용 pre.yaml을 만들었다가 OpenDev 패턴에 맞춰 공통
  pre.yaml로 되돌린 revert 포함)

## 관련 참고

- `docs/manual/08-translation-pipeline.md` — 파이프라인 전체 흐름 (tutorial)
- OpenStack 원본:
  `https://opendev.org/openstack/openstack-zuul-jobs/raw/branch/master/roles/prepare-zanata-client/files/propose_translation_update.sh`
