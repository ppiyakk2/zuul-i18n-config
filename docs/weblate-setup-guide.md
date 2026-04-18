# Weblate Project Setup Guide

이 문서는 Weblate에 OpenStack 프로젝트의 번역 환경을 설정하는 전체 과정을 설명한다.

## Weblate 구조 개요

```
Project (e.g. contributor-guide)
  └── Category (= branch, e.g. master, stable/2026.01)
       └── Component (= 번역 문서, e.g. doc-common, doc-users)
            └── Language (= 번역 언어, e.g. ko_KR, ja)
```

| 개념 | Weblate 용어 | OpenStack 매핑 | 예시 |
|------|-------------|---------------|------|
| Project | Project | OpenStack 프로젝트 | contributor-guide |
| Category | Category | Git branch | master, stable/2026.01 |
| Component | Component | 번역 대상 문서 | doc-common, doc-users |
| Language | Language | 번역 언어 | ko_KR, ja, zh_CN |

## 사전 요구사항

### 1. Weblate API 인증 설정

`~/.config/weblate` 파일 (wlc 형식):

```ini
[weblate]
url = https://weblate.printf.kr/api/

[keys]
https://weblate.printf.kr/api/ = wlu_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> **주의:** `configparser`가 URL의 `:`를 구분자로 오인하므로, 파싱 시 `delimiters=("=",)` 옵션을 사용해야 한다.

### 2. POT 파일 빌드 환경

서버에 아래 패키지가 필요하다:

```bash
sudo apt-get install python3.12-venv gettext
python3 -m venv .venv
source .venv/bin/activate
pip install sphinx openstackdocstheme
```

## 전체 설정 과정

### Step 1: POT 파일 빌드

contributor-guide 소스에서 Sphinx gettext builder로 POT 파일을 추출한다.
이 과정은 `common_translation_update.sh`의 `extract_messages_doc` 함수와 동일하다.

```bash
cd /path/to/contributor-guide
source .venv/bin/activate

# 1. Sphinx로 메시지 추출
mkdir -p doc/build/gettext
sphinx-build -b gettext doc/source doc/build/gettext/

# 2. 디렉토리별 POT 생성
mkdir -p doc/source/locale
for f in doc/build/gettext/*.pot; do
    fn=$(basename "$f" .pot)
    if [ -d "doc/source/$fn" ]; then
        # 디렉토리에 대응하는 POT → doc-<dirname>.pot
        msgcat --use-first --sort-by-file "$f" > "doc/source/locale/doc-$fn.pot"
        rm "$f"
    fi
done

# 3. 나머지 top-level 파일 → doc.pot으로 병합
if ls doc/build/gettext/*.pot 1>/dev/null 2>&1; then
    msgcat --use-first --sort-by-file doc/build/gettext/*.pot > doc/source/locale/doc.pot
fi

# 4. 정리
rm -rf doc/build/gettext/
```

**결과물** (`doc/source/locale/`):

| 파일명 | 대응 디렉토리 |
|--------|--------------|
| doc.pot | top-level rst 파일 (index.rst 등) |
| doc-code-and-documentation.pot | doc/source/code-and-documentation/ |
| doc-common.pot | doc/source/common/ |
| doc-contributing.pot | doc/source/contributing/ |
| doc-non-code-contribution.pot | doc/source/non-code-contribution/ |
| doc-operators.pot | doc/source/operators/ |
| doc-organizations.pot | doc/source/organizations/ |
| doc-users.pot | doc/source/users/ |

### Step 2: POT 파일 전처리

Weblate에 업로드하기 전에 POT 파일에 두 가지 처리가 필요하다.

#### 2-1. msgen으로 영어 원문 채우기

POT 파일은 `msgstr`이 비어 있다. `po-mono` 형식에서는 `msgstr`이 소스 텍스트로 표시되므로, `msgen`으로 `msgid` 내용을 `msgstr`에 복사해야 한다.

```bash
msgen input.pot -o output.pot
```

**Before:**
```
msgid "Testing Changes with DevStack"
msgstr ""
```

**After:**
```
msgid "Testing Changes with DevStack"
msgstr "Testing Changes with DevStack"
```

> `msgen`을 적용하지 않으면 Weblate 번역 화면에서 English 소스 텍스트가 비어 보인다.

#### 2-2. Language 헤더에 `enu` 설정

POT 파일의 헤더에 `"Language: enu\n"` 를 추가해야 한다.

```
"Content-Transfer-Encoding: 8bit\n"
"Language: enu\n"
```

> **왜 `enu`인가?**
>
> Weblate에는 내장된 `en` 의사 언어(pseudo-language)가 있으며, 이 언어의 alias 목록에 `en_us`가 포함되어 있다.
> 따라서 `Language: en_US`를 사용하면 실제 `en_US` 언어(id=1034)가 아닌 `en` 의사 언어(id=None)로 매핑되어 "Language matching query does not exist" 오류가 발생한다.
>
> | 언어 | id | aliases |
> |------|----|---------|
> | en (내장, 수정/삭제 불가) | None | base, en_en, **en_us**, eng, enp, source |
> | en_US (실제 사용) | 1034 | **enu**, us |
>
> `enu`는 `en_US`의 고유 alias이므로 충돌 없이 올바른 언어로 매핑된다.

### Step 3: Weblate에 등록

`setup_weblate_project.py` 스크립트를 사용한다.

```bash
python3 setup_weblate_project.py \
    --config ~/.config/weblate \
    --project-name contributor-guide \
    --project-web "https://docs.openstack.org/contributor-guide/" \
    --branches master "stable/2026.01" \
    --pot-dir /path/to/pot-files/
```

스크립트가 수행하는 작업:

1. **Project 생성** — `POST /api/projects/`
   - 필수: `name`, `slug`, `web` (빈 문자열 불가)

2. **Category 생성** — `POST /api/categories/`
   - branch 이름을 slug로 변환 (`/` → `-`, `.` → `-`)
   - 예: `stable/2026.01` → `stable-2026-01`

3. **POT 전처리** — `msgen` + `Language: enu` 헤더 추가

4. **Component 생성** — `POST /api/projects/{project}/components/` (multipart form)

## Component 생성 조건 및 설정

### 필수 파라미터

| 파라미터 | 값 | 설명 |
|---------|---|------|
| `name` | 컴포넌트 이름 | 예: `doc-common` |
| `slug` | 컴포넌트 slug | 예: `doc-common` |
| `file_format` | `po-mono` | **반드시 monolingual PO** 사용 |
| `source_language` | `en_US` | 소스 언어 코드 |
| `docfile` | POT 파일 | msgen + Language:enu 적용된 파일 |

### 선택 파라미터

| 파라미터 | 값 | 설명 |
|---------|---|------|
| `category` | 카테고리 API URL | 예: `http://weblate.printf.kr/api/categories/1/` |

### 왜 po-mono인가?

| 형식 | 방식 | msgid 역할 | msgstr 역할 | docfile 지원 |
|------|------|-----------|-------------|-------------|
| `po` (bilingual) | 이중 언어 | 소스 텍스트 | 번역 텍스트 | 불가 ("base file for bilingual" 오류) |
| `po-mono` (monolingual) | 단일 언어 | 키/식별자 | 실제 텍스트 | 가능 (template으로 사용) |

- `po` (bilingual) 형식은 `docfile` 업로드 시 "You can not use a base file for bilingual translation" 오류 발생
- `po-mono`를 사용하면 POT를 template으로 업로드할 수 있음
- 단, `msgstr`에 영어 원문이 채워져 있어야 소스 텍스트로 표시됨 (`msgen` 필수)

### 기타 시도했으나 실패한 방식들

| 방식 | 오류 |
|------|------|
| `po` + `docfile` | "You can not use a base file for bilingual translation" |
| `po` + `vcs:local` (파일 없음) | "The file mask did not match any files" |
| `po` + `zipfile` | HTTP 500 (서버 오류) |
| `po-mono` + `docfile` + `Language: en_US` | "Language matching query does not exist" (en alias 충돌) |
| `po` + `manage_units: true` | "The file mask did not match any files" (무시됨) |

### Slug 제약사항

Weblate slug에는 영문자, 숫자, 하이픈(`-`), 언더스코어(`_`)만 허용된다.

- `/` → `-` (branch 구분자)
- `.` → `-` (버전 번호)
- 예: `stable/2026.01` → `stable-2026-01`

## 스크립트 사용법

### 전체 설정 (프로젝트 + 카테고리 + 컴포넌트)

```bash
python3 setup_weblate_project.py \
    --config ~/.config/weblate \
    --project-name contributor-guide \
    --branches master "stable/2026.01" \
    --pot-dir /path/to/pot-files/
```

### 특정 컴포넌트만 생성

```bash
python3 setup_weblate_project.py \
    --config ~/.config/weblate \
    --project-name contributor-guide \
    --branches master \
    --components doc-common doc-users \
    --pot-dir /path/to/pot-files/
```

### CLI 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--config` | `~/.config/weblate` | weblate.ini 경로 |
| `--project-name` | `contributor-guide` | 프로젝트 이름 |
| `--project-slug` | (project-name과 동일) | 프로젝트 slug |
| `--project-web` | OpenStack docs URL | 프로젝트 웹사이트 |
| `--branches` | `master` | 카테고리로 생성할 branch 목록 |
| `--components` | 8개 기본 컴포넌트 | 생성할 컴포넌트 목록 |
| `--pot-dir` | (없음) | POT 파일 디렉토리 |
| `--no-verify-ssl` | false | SSL 검증 비활성화 |

## POT 업로드 (upload_pot_weblate.py)

커밋이 머지된 후 새로운 POT를 추출하고 Weblate에 업데이트하는 스크립트.
`upstream_translation_update_weblate.sh`에서 호출된다.

### 동작 순서

```
1. POT 파일 목록 수집 (translation-source/*.pot)
2. 각 POT에 대해:
   a. msgen 적용 (msgstr에 영어 원문 채우기)
   b. Language:enu 헤더 추가
   c. 컴포넌트 존재 여부 확인 → 없으면 자동 생성
   d. 소스 파일 업로드 (POST /api/translations/.../en_US/file/)
   e. 결과 로깅 (성공/실패/skip)
3. 요약 출력
```

### 사용법

```bash
python3 upload_pot_weblate.py \
    --config ~/.config/weblate \
    --project contributor-guide \
    --category master \
    --pot-dir translation-source/
```

### upstream_translation_update_weblate.sh에서의 호출

```bash
python3 "$SCRIPTSDIR/upload_pot_weblate.py" \
    --config ~/.config/weblate \
    --project "$WEBLATE_PROJECT" \
    --category "$WEBLATE_BRANCH" \
    --pot-dir translation-source/
```

기존의 curl 반복 루프를 대체한다:

```bash
# 기존 (제거됨)
for pot in translation-source/*.pot; do
  msgen "$pot" -o "$pot"
  curl -X POST -F "file=@${pot}" -F "method=replace" \
    "${WEBLATE_URL}/api/translations/.../en_US/file/"
done

# 개선 (Python 스크립트 한 줄 호출)
python3 "$SCRIPTSDIR/upload_pot_weblate.py" --config ... --project ... --category ... --pot-dir ...
```

### 컴포넌트 존재 여부 확인 로직

카테고리별로 컴포넌트를 구분한다. API 응답의 `category` 필드가 URL 형태이므로,
target category의 URL을 먼저 조회한 뒤 일치 여부를 비교한다.

```python
# category URL 기반 매칭 (slug 단순 비교 아님)
target_cat_url = setup.get_category_url(project, category_slug)
for c in existing_components:
    if c.get("category") == target_cat_url:
        existing_slugs.add(c.get("slug"))
```

### weblate.ini 형식 호환

`SimpleIniConfig`는 두 가지 형식을 지원한다:

```ini
# 형식 1: Zuul 템플릿 ([weblate] 섹션에 key 직접)
[weblate]
url = https://weblate.printf.kr/api/
key = wlu_xxxxx

# 형식 2: wlc 공식 형식 ([keys] 섹션에 URL→token 매핑)
[weblate]
url = https://weblate.printf.kr/api/

[keys]
https://weblate.printf.kr/api/ = wlu_xxxxx
```

현재 Zuul 템플릿(`weblate.ini.j2`)은 형식 2 (wlc 형식)를 사용한다.

### CLI 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--config` | `~/.config/weblate` | weblate.ini 경로 |
| `--project` | (필수) | Weblate 프로젝트 slug |
| `--category` | (필수) | Branch 이름 (slug로 자동 변환) |
| `--pot-dir` | (필수) | POT 파일 디렉토리 |
| `--source-language` | `en_US` | 소스 언어 코드 |
| `--auto-create` | true | 없는 컴포넌트 자동 생성 |
| `--no-verify-ssl` | false | SSL 검증 비활성화 |

## 테스트 환경 정보

| 항목 | 값 |
|------|---|
| Weblate URL | https://weblate.printf.kr |
| Weblate 버전 | 5.15.1 |
| 인증 | ~/.config/weblate (wlc 형식) |
| Zuul 서버 | 133.186.247.137 (ubuntu, SSH key: ~/.ssh/ne-se-pub-test-pyk.pem) |
| Job 실행 노드 | 133.186.244.143 / 192.168.0.34 (Ubuntu 24.04) |
| 소스 경로 (노드) | ~/src/github.com/ppiyakk2/contributor-guide (Zuul이 자동 동기화) |
