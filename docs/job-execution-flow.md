# Job 실행 흐름

> `upstream-translation-update` job이 트리거되어 실행되기까지의 전체 흐름.

## 설정 파일 간 연결 관계

```
projects.yaml  ──"어떤 job을 실행할지"──►  jobs.yaml
                                              │
                                    run 필드로 playbook 지정
                                              │
                                              ▼
                                    playbooks/xxx/run.yaml
                                              │
                                    include_role로 role 호출
                                              │
                                              ▼
                                    roles/prepare-weblate-client/
                                        tasks/main.yaml
```

- **projects.yaml**: 프로젝트별로 어떤 파이프라인에서 어떤 job을 돌릴지 매핑
- **jobs.yaml**: job 정의 — 어떤 playbook을 실행할지(`run`), 어떤 secret/vars를 넘길지
- **playbook**: 실제 Ansible 태스크들. `include_role`로 role을 호출
- **role**: 재사용 가능한 태스크 묶음 (wlc 설치 + 설정 파일 작성)

## 전체 실행 흐름

master에 push가 들어오면 `post` 파이프라인이 `upstream-translation-update` job을 실행한다.

```
zuul.d/projects.yaml          "contributor-guide의 post 파이프라인에서
       │                       upstream-translation-update 실행해라"
       ▼
zuul.d/jobs.yaml               upstream-translation-update job 정의
       │                       ├── parent: base  →  post-run: playbooks/base/post-logs.yaml
       │                       ├── run: playbooks/upstream-translation-update/run.yaml
       │                       ├── secrets: weblate_api_credentials
       │                       └── vars: weblate_component: "contributor-guide/main"
       ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Executor가 실행하는 순서                                           │
│                                                                     │
│  1. [RUN] playbooks/upstream-translation-update/run.yaml            │
│     │                                                               │
│     ├── task: Prepare Weblate client                                │
│     │   └── include_role: prepare-weblate-client    ◄── role 호출   │
│     │       vars:                                                   │
│     │         weblate_url: "{{ weblate_api_credentials.url }}"      │
│     │         weblate_token: "{{ weblate_api_credentials.token }}"  │
│     │                                                               │
│     │   role 내부 실행 (roles/prepare-weblate-client/tasks/main.yaml)│
│     │     ├── pip install wlc==1.17.2                               │
│     │     ├── mkdir ~/.config/                                      │
│     │     └── weblate.ini 생성 (url + token)                        │
│     │                                                               │
│     ├── task: sphinx-build -b gettext → POT 파일 8개 추출           │
│     │                                                               │
│     └── task: wlc upload (POT파일 × 8)    ◄── 여기서 실패 중        │
│                                                                     │
│  2. [POST-RUN] playbooks/base/post-logs.yaml  (성공/실패 무관 실행) │
│     ├── 로그 파일을 /srv/static/logs/{uuid}/ 로 복사                │
│     ├── zuul-manifest.json + .gz 생성                               │
│     └── zuul_return으로 log_url 반환                                │
└─────────────────────────────────────────────────────────────────────┘
```

## 각 파일의 역할

### zuul.d/projects.yaml

프로젝트와 파이프라인-job 매핑:

```yaml
- project:
    name: ppiyakk2/contributor-guide
    check:
      jobs:
        - noop                          # PR 검증 (현재 noop)
    post:
      jobs:
        - upstream-translation-update   # master push 시 실행
    periodic:
      jobs:
        - propose-translation-update    # 매일 UTC 02:00
```

### zuul.d/jobs.yaml

job 정의. `parent: base`를 통해 `post-run`(로그 복사)을 상속:

```yaml
- job:
    name: base
    parent: null
    post-run: playbooks/base/post-logs.yaml   # 모든 자식 job이 상속
    nodeset:
      nodes: []

- job:
    name: upstream-translation-update
    parent: base                               # base의 post-run 상속
    run: playbooks/upstream-translation-update/run.yaml
    secrets:
      - name: weblate_api_credentials
        secret: weblate_api_credentials
    vars:
      weblate_component: "contributor-guide/main"
```

### playbooks/upstream-translation-update/run.yaml

실제 실행되는 Ansible playbook. `include_role`로 role을 호출:

```yaml
- name: Prepare Weblate client
  include_role:
    name: prepare-weblate-client
  vars:
    weblate_url: "{{ weblate_api_credentials.url }}"
    weblate_token: "{{ weblate_api_credentials.token }}"
  when: weblate_api_credentials is defined
```

### roles/prepare-weblate-client/tasks/main.yaml

재사용 가능한 role. wlc 설치 + 설정 파일 작성:

```yaml
- name: Install wlc (Weblate CLI client)
  pip:
    name: "wlc=={{ weblate_client_version }}"      # defaults: 1.17.2

- name: Ensure wlc config directory exists
  file:
    path: "{{ weblate_config_path | dirname }}"     # ~/.config/
    state: directory

- name: Write wlc config file
  template:
    src: weblate.ini.j2                             # [weblate]\nurl=...\nkey=...
    dest: "{{ weblate_config_path }}"               # ~/.config/weblate
  no_log: true                                      # 토큰 노출 방지
```

## base job의 post-run 상속

`base` job에 정의된 `post-run`은 모든 자식 job이 자동 상속한다:

- `upstream-translation-update` → base 상속 → post-run 실행
- `propose-translation-update` → base 상속 → post-run 실행

따라서 **어떤 job이든** 실행 후 자동으로 로그가 nginx 서빙 디렉토리에 복사되고, Zuul 웹 UI에서 볼 수 있다.

## config 변경 반영 방법

| 변경 위치 | 반영 방법 | 이유 |
|-----------|----------|------|
| `playbooks/`, `roles/` | **push만 하면 끝** | Executor가 job 실행 시 매번 GitHub에서 최신 코드를 fetch |
| `zuul.d/` (jobs, pipelines, projects, secrets) | **push + webhook 시뮬레이션** 필요 | Scheduler가 ZooKeeper 캐시에서 config를 읽으므로, push 이벤트로 reconfig 트리거 필요 |
