# 03. 설정 구조

Zuul의 모든 설정은 `zuul.d/` 디렉토리 안에 YAML 파일로 존재한다.
이 장에서는 각 설정 파일의 역할과 서로의 관계를 설명한다.

## 설정 파일 전체 구조

```
zuul.d/
  ├── pipelines.yaml   ← "언제" 실행할지 (트리거 조건)
  ├── jobs.yaml        ← "무엇을" 실행할지 (job 정의)
  ├── projects.yaml    ← "어떤 프로젝트에" 적용할지 (프로젝트-job 매핑)
  └── secrets.yaml     ← "어떤 인증 정보를" 쓸지 (암호화된 시크릿)
```

이 네 파일이 하나의 질문에 답한다:

> **"어떤 프로젝트에서 어떤 이벤트가 발생하면, 어떤 job을 실행하고, 어떤 인증 정보를 사용하는가?"**

## Pipeline (pipelines.yaml)

Pipeline은 **"언제 job을 실행할지"**를 정의한다.

```yaml
- pipeline:
    name: post
    manager: independent
    trigger:
      github:
        - event: push
          ref: ^refs/heads/master$
```

### 주요 필드

| 필드 | 설명 |
|------|------|
| `name` | 파이프라인 이름 (check, post, periodic 등) |
| `manager` | 실행 전략. `independent`(독립 실행), `dependent`(순차 게이팅) |
| `trigger` | 어떤 이벤트에 반응할지 |

### 우리 프로젝트의 Pipeline

| Pipeline | 트리거 | 용도 |
|----------|--------|------|
| `check` | PR 생성/업데이트 | PR 검증 (현재는 noop) |
| `post` | master에 push | 번역 원본(POT) 추출 → Weblate 업로드 |
| `periodic` | 매일 02:00 UTC (timer) | Weblate에서 번역 다운로드 → PR 제안 |

### Pipeline Manager 종류

```
independent (독립)
  ├── Job A ──→ 결과
  └── Job B ──→ 결과    ← 서로 영향 없음

dependent (순차 게이팅)
  ├── Job A ──→ 성공 → Job B 시작
  └── Job A 실패 → Job B 취소    ← 앞의 결과에 의존
```

`post`와 `periodic`은 `independent`를 사용한다. 이미 merge된 후이므로 게이팅이 필요 없다.

## Job (jobs.yaml)

Job은 **"무엇을 실행할지"**를 정의한다.

```yaml
- job:
    name: upstream-translation-update
    parent: base
    pre-run: playbooks/upstream-translation-update/pre.yaml
    run: playbooks/upstream-translation-update/run.yaml
    required-projects:
      - <your-org>/contributor-guide
    secrets:
      - weblate_api_credentials
    vars:
      weblate_project: contributor-guide
```

### 주요 필드

| 필드 | 설명 |
|------|------|
| `name` | job 이름 |
| `parent` | 상속할 부모 job. `base`를 상속하면 base의 pre-run, post-run이 자동 적용 |
| `pre-run` | 메인 실행 전에 돌릴 playbook (환경 준비) |
| `run` | 메인 playbook (실제 작업) |
| `post-run` | 메인 실행 후에 돌릴 playbook (로그 수집 등) |
| `required-projects` | 함께 checkout할 프로젝트 목록 |
| `secrets` | 사용할 암호화된 인증 정보 |
| `vars` | playbook에 전달할 변수 |
| `nodeset` | 실행할 노드 구성 |

### Job 상속

```
base (parent: null)
  ├── pre-run: playbooks/base/pre.yaml
  ├── post-run: playbooks/base/post-logs.yaml
  └── nodeset: ubuntu-noble
      │
      ├── upstream-translation-update (parent: base)
      │     ├── pre-run: playbooks/upstream-translation-update/pre.yaml
      │     └── run: playbooks/upstream-translation-update/run.yaml
      │
      └── propose-translation-update (parent: base)
            ├── pre-run: playbooks/propose-translation-update/pre.yaml
            └── run: playbooks/propose-translation-update/run.yaml
```

`parent: base`를 지정하면:
- base의 `pre-run`이 **먼저** 실행된다
- base의 `post-run`이 **나중에** 실행된다
- base의 `nodeset`을 상속받는다

실행 순서:
```
1. base/pre.yaml           ← base에서 상속
2. upstream-translation-update/pre.yaml  ← 이 job의 pre-run
3. upstream-translation-update/run.yaml  ← 이 job의 run
4. base/post-logs.yaml     ← base에서 상속
```

### base job

모든 job의 공통 부모. `parent: null`은 "더 이상 상속할 부모가 없다"는 뜻이다.

```yaml
- job:
    name: base
    parent: null
    description: Base job.
    pre-run: playbooks/base/pre.yaml
    post-run: playbooks/base/post-logs.yaml
    nodeset:
      nodes:
        - name: ubuntu-noble
          label: ubuntu-noble
```

base job이 하는 일:
- **pre-run**: 소스 코드를 원격 노드에 동기화, zuul_console 시작
- **post-run**: 로그 파일을 수집하여 로그 서버에 저장
- **nodeset**: 모든 job이 ubuntu-noble 노드에서 실행되도록 지정

## Project (projects.yaml)

Project는 **"어떤 프로젝트에 어떤 job을 적용할지"**를 매핑한다.

```yaml
- project:
    name: <your-org>/contributor-guide
    check:
      jobs:
        - noop
    post:
      jobs:
        - upstream-translation-update
    periodic:
      jobs:
        - propose-translation-update
```

이 설정의 의미:
- `<your-org>/contributor-guide` 프로젝트에 대해
- PR이 오면 (`check`) → noop (아무것도 안 함)
- master에 push되면 (`post`) → upstream-translation-update 실행
- 매일 02:00 UTC (`periodic`) → propose-translation-update 실행

## Secret (secrets.yaml)

Secret은 **암호화된 인증 정보**이다.

```yaml
- secret:
    name: weblate_api_credentials
    data:
      url: !encrypted/pkcs1-oaep
        - nSbC7x2F...  (암호화된 데이터)
      token: !encrypted/pkcs1-oaep
        - aB3kD9e...  (암호화된 데이터)
```

### Secret의 특징

- **프로젝트 공개키로 암호화**된다. Zuul 서버만 복호화할 수 있다.
- **Trusted playbook에서만 사용 가능**하다 (보안상 이유).
- Job 정의에서 `secrets:`로 참조하면 playbook에서 변수로 접근할 수 있다.

```yaml
# jobs.yaml에서 secret 연결
- job:
    name: upstream-translation-update
    secrets:
      - weblate_api_credentials

# playbook에서 사용
- shell: |
    echo "URL is {{ weblate_api_credentials.url }}"
  environment:
    WEBLATE_URL: "{{ weblate_api_credentials.url }}"
```

Secret에 대한 자세한 내용은 [07. Secret 관리](07-secrets.md)에서 다룬다.

## 설정 파일 간의 관계

```
projects.yaml                    pipelines.yaml
  "contributor-guide의             "post pipeline은
   post pipeline에                  master push에
   upstream-translation-update      반응한다"
   job을 연결한다"
        │                               │
        └──────────┬────────────────────┘
                   ▼
              jobs.yaml
  "upstream-translation-update job은
   base를 상속하고,
   이 playbook을 실행하고,
   이 secret을 사용한다"
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
   playbooks/   roles/   secrets.yaml
```

## Config Project vs Untrusted Project

Zuul에는 두 종류의 프로젝트가 있다.

| 구분 | Config Project | Untrusted Project |
|------|---------------|-------------------|
| 역할 | Zuul 설정을 정의 | 실제 소스 코드 |
| 설정 범위 | pipeline, job, project, secret 모두 정의 가능 | job, project만 정의 가능 |
| Playbook 실행 | **Trusted** (executor에서 실행) | **Untrusted** (sandbox에서 실행) |
| Secret 접근 | 가능 | 불가능 |
| 우리 프로젝트 | `<your-org>/zuul-i18n-config` | `<your-org>/contributor-guide` |

Config project의 playbook은 **trusted**로 실행된다.
이것은 Secret에 접근할 수 있고, executor에서 직접 실행된다는 의미이다.

## Tenant 설정

Tenant는 Zuul의 최상위 격리 단위이다. 하나의 Zuul 서버에 여러 tenant를 운영할 수 있다.

```yaml
# main.yaml (Zuul 서버의 tenant 설정)
- tenant:
    name: i18n-test
    source:
      github:
        config-projects:
          - <your-org>/zuul-i18n-config:
              load-branch: main
        untrusted-projects:
          - <your-org>/contributor-guide
```

이 설정은 Zuul 서버의 main.yaml에 있으며, 우리 config 저장소 안에 있지 않다.
Zuul 관리자가 설정한다.

## 다음 문서

→ [04. Job 실행 모델](04-job-execution.md): Job이 실제로 어떻게 실행되는지 상세히 알아본다.
