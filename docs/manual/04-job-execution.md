# 04. Job 실행 모델

## Job 실행의 3단계

모든 Zuul job은 세 단계로 실행된다.

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│ pre-run  │ ──→ │   run    │ ──→ │ post-run │
│ (준비)    │     │ (실행)    │     │ (정리)    │
└──────────┘     └──────────┘     └──────────┘
```

| 단계 | 역할 | 실패 시 |
|------|------|---------|
| `pre-run` | 환경 준비 (패키지 설치, 소스 동기화) | job 전체 실패 |
| `run` | 실제 작업 수행 | post-run은 **여전히 실행됨** |
| `post-run` | 로그 수집, 결과 보고 | 결과에 영향 없음 |

`run`이 실패해도 `post-run`은 실행된다는 점이 중요하다.
로그를 수집해야 실패 원인을 분석할 수 있기 때문이다.

## Job 상속과 실행 순서

`parent`로 상속하면 부모의 pre-run/post-run이 자동 포함된다.

```yaml
# base job
- job:
    name: base
    parent: null
    pre-run: playbooks/base/pre.yaml           # ① 가장 먼저
    post-run: playbooks/base/post-logs.yaml     # ⑤ 가장 나중에

# 자식 job
- job:
    name: upstream-translation-update
    parent: base
    pre-run: playbooks/upstream-translation-update/pre.yaml   # ②
    run: playbooks/upstream-translation-update/run.yaml       # ③
    # (post-run 없음 → base의 post-run만 실행)                # ④ → ⑤
```

실행 순서:
```
① base/pre.yaml                    ← 소스 동기화, zuul_console
② upstream-translation-update/pre.yaml  ← sphinx, babel, weblate 설치
③ upstream-translation-update/run.yaml  ← POT 추출, Weblate 업로드
④ (이 job의 post-run 없음)
⑤ base/post-logs.yaml              ← 로그 수집
```

pre-run은 **부모 → 자식** 순서, post-run은 **자식 → 부모** 순서(역순)로 실행된다.

## Executor와 Node의 관계

Job 실행에는 두 곳이 관여한다.

```
┌────────────────────────┐          ┌────────────────────────┐
│      Executor          │   SSH    │     Worker Node        │
│  (zuul-executor 컨테이너) │ ───────→ │  (ubuntu-noble)        │
│                        │          │                        │
│  ・Git checkout        │          │  ・실제 작업 수행         │
│  ・Ansible 실행         │          │  ・패키지 설치           │
│  ・Trusted playbook    │          │  ・스크립트 실행          │
│  ・Secret 복호화        │          │                        │
│  ・로그 저장            │          │                        │
└────────────────────────┘          └────────────────────────┘
```

### 어디서 실행되는가?

Playbook의 `hosts` 필드가 결정한다.

| hosts 값 | 실행 위치 | 용도 |
|----------|----------|------|
| `all` | Worker node | 일반적인 작업 (빌드, 테스트, 스크립트 실행) |
| `localhost` | Executor | 로그 수집, executor 로컬 작업 |

```yaml
# Worker node에서 실행
- hosts: all
  tasks:
    - shell: ./run-tests.sh

# Executor에서 실행
- hosts: localhost
  tasks:
    - copy:
        src: "{{ zuul.executor.log_root }}/job-output.txt"
        dest: /srv/static/logs/
```

### 소스 코드는 어디에?

**Executor가 checkout한다.** Worker node에는 자동으로 복사되지 않는다.

```
Executor:
  {{ zuul.executor.work_root }}/src/github.com/<your-org>/contributor-guide/
  └── (소스 코드가 여기 있음)

Worker Node:
  ~/src/github.com/<your-org>/contributor-guide/
  └── (비어 있음! pre-run에서 복사해야 함)
```

이것이 `playbooks/base/pre.yaml`에서 `synchronize` 모듈로 소스를 복사하는 이유이다:

```yaml
- name: Sync project source from executor to node
  synchronize:
    src: "{{ zuul.executor.work_root }}/src/{{ zuul.project.canonical_name }}/"
    dest: "{{ ansible_user_dir }}/{{ zuul.project.src_dir }}/"
```

`synchronize` 모듈은 rsync 기반이며, executor → node 방향으로 파일을 복사한다.

## Trusted vs Untrusted

Zuul에서 가장 중요한 보안 개념이다.

### Trusted Playbook

**Config project** (`zuul-i18n-config`)에 있는 playbook은 trusted로 실행된다.

- Secret에 접근할 수 있다
- Executor에서 실행된다 (localhost 사용 시)
- 노드에 대한 전체 제어 권한이 있다

### Untrusted Playbook

**일반 프로젝트** (`contributor-guide`)에 있는 playbook은 untrusted로 실행된다.

- Secret에 접근할 수 **없다**
- Sandbox 안에서 실행된다
- 제한된 Ansible 모듈만 사용 가능

### 왜 이런 구분이 필요한가?

PR을 올리는 누구나 playbook을 수정할 수 있다.
만약 untrusted playbook이 secret에 접근할 수 있다면:

```yaml
# 악의적인 PR
- hosts: all
  tasks:
    - debug:
        msg: "{{ weblate_api_credentials.token }}"
    # → 토큰이 로그에 노출!
```

따라서 secret은 config project의 trusted playbook에서만 사용할 수 있다.

## Zuul 변수

Playbook에서 사용할 수 있는 Zuul 내장 변수들이다.

### 자주 쓰는 변수

| 변수 | 예시 | 설명 |
|------|------|------|
| `zuul.project.name` | `<your-org>/contributor-guide` | 프로젝트 전체 이름 |
| `zuul.project.short_name` | `contributor-guide` | 프로젝트 짧은 이름 |
| `zuul.project.canonical_name` | `github.com/<your-org>/contributor-guide` | 정규 이름 (호스트 포함) |
| `zuul.project.src_dir` | `src/github.com/<your-org>/contributor-guide` | 상대 소스 경로 |
| `zuul.branch` | `master` | 대상 브랜치 |
| `zuul.pipeline` | `post` | 실행 중인 파이프라인 |
| `zuul.job` | `upstream-translation-update` | 실행 중인 job 이름 |
| `ansible_user_dir` | `/home/ubuntu` | 노드의 홈 디렉토리 |

### Executor 전용 변수

| 변수 | 설명 |
|------|------|
| `zuul.executor.work_root` | Executor에서 소스가 checkout된 루트 경로 |
| `zuul.executor.log_root` | Executor의 로그 저장 경로 |
| `zuul.executor.src_root` | `{{ work_root }}/src` |

이 변수들은 `hosts: localhost`에서만 의미가 있다 (executor에서 실행될 때).

### 주의사항

- `zuul.project.src_dir`은 **상대 경로**이다. 절대 경로가 필요하면 `{{ ansible_user_dir }}/{{ zuul.project.src_dir }}`로 조합한다.
- `zuul.project.canonical_name`에는 `github.com/`이 포함된다. URL을 만들 때 `https://`만 앞에 붙이면 된다.

## 다음 문서

→ [05. Playbook과 Role](05-playbook-and-role.md): Ansible playbook과 role로 job을 작성하는 방법을 알아본다.
