# 05. Playbook과 Role

Zuul의 실행 로직은 Ansible playbook으로 작성한다.
이 장에서는 playbook과 role의 구조, 작성법, 변수 전달 방식을 설명한다.

## 디렉토리 구조

```
zuul-i18n-config/
  ├── playbooks/
  │   ├── base/
  │   │   ├── pre.yaml              ← 모든 job 공통 사전 준비
  │   │   └── post-logs.yaml        ← 모든 job 공통 로그 수집
  │   ├── upstream-translation-update/
  │   │   ├── pre.yaml              ← 번역 업로드 job 전용 준비
  │   │   └── run.yaml              ← 번역 업로드 실행
  │   └── propose-translation-update/
  │       ├── pre.yaml              ← 번역 제안 job 전용 준비
  │       └── run.yaml              ← 번역 제안 실행
  └── roles/
      ├── ensure-sphinx/            ← Sphinx 문서 빌드 도구 설치
      ├── ensure-babel/             ← Babel i18n 도구 설치
      └── prepare-weblate-client/   ← Weblate CLI + 스크립트 배포
```

## Playbook 작성

### 기본 구조

```yaml
- name: 이 play의 설명
  hosts: all          # 어디서 실행할지
  tasks:
    - name: 첫 번째 작업
      shell: echo "hello"

    - name: 두 번째 작업
      file:
        path: /tmp/test
        state: directory
```

### hosts 선택

| hosts | 실행 위치 | 언제 사용 |
|-------|----------|----------|
| `all` | Worker node | 대부분의 작업 |
| `localhost` | Executor | 로그 수집, executor 로컬 작업 |

```yaml
# 노드에서 실행하는 경우
- hosts: all
  tasks:
    - name: 스크립트 실행
      shell: bash ~/scripts/build.sh

# Executor에서 실행하는 경우
- hosts: localhost
  connection: local
  tasks:
    - name: 로그 복사
      copy:
        src: "{{ zuul.executor.log_root }}/job-output.txt"
        dest: /srv/static/logs/
```

`hosts: localhost`일 때는 `connection: local`을 함께 써야 한다.
SSH가 아닌 로컬 실행임을 명시하는 것이다.

### Role 포함

```yaml
- hosts: all
  roles:
    - ensure-sphinx
    - ensure-babel
    - prepare-weblate-client
```

또는 task 안에서:

```yaml
- hosts: all
  tasks:
    - include_role:
        name: ensure-sphinx
      vars:
        doc_building_packages:
          - sphinx
          - reno
```

## Role 구조

Role은 재사용 가능한 작업 단위이다.

```
roles/prepare-weblate-client/
  ├── defaults/
  │   └── main.yaml          ← 기본 변수값
  ├── tasks/
  │   └── main.yaml          ← 실행할 task 목록
  ├── templates/
  │   └── weblate.ini.j2     ← Jinja2 템플릿
  ├── files/
  │   ├── upstream_translation_update_weblate.sh
  │   ├── common_translation_update.sh
  │   ├── upload_pot_weblate.py
  │   └── ...                ← 노드에 복사할 파일들
  └── README.rst             ← 문서
```

### defaults/main.yaml

Role의 기본 변수값을 정의한다. Playbook이나 job에서 덮어쓸 수 있다.

```yaml
# roles/prepare-weblate-client/defaults/main.yaml
weblate_config_path: "{{ ansible_user_dir }}/.config/weblate"
```

### tasks/main.yaml

Role이 실행할 작업 목록이다.

```yaml
# roles/prepare-weblate-client/tasks/main.yaml
- name: Install wlc
  pip:
    name: wlc==1.15
    executable: pip3

- name: Write config
  template:
    src: weblate.ini.j2
    dest: "{{ weblate_config_path }}"

- name: Copy scripts
  copy:
    src: "{{ item }}"
    dest: "{{ ansible_user_dir }}/scripts/{{ item }}"
    mode: '0755'
  loop:
    - upstream_translation_update_weblate.sh
    - common_translation_update.sh
    - upload_pot_weblate.py
```

### templates/

Jinja2 템플릿 파일을 저장한다. `template` 모듈이 변수를 치환하여 노드에 배포한다.

```ini
# roles/prepare-weblate-client/templates/weblate.ini.j2
[weblate]
url = {{ weblate_api_credentials.url }}

[keys]
{{ weblate_api_credentials.url }} = {{ weblate_api_credentials.token }}
```

`{{ weblate_api_credentials.url }}`은 Zuul secret에서 복호화된 실제 URL로 치환된다.

### files/

노드에 그대로 복사할 파일들이다. 템플릿 치환 없이 원본 그대로 복사된다.
`copy` 모듈로 배포한다.

## 변수 전달 흐름

변수가 playbook에 도달하는 경로는 여러 가지이다.

```
zuul.d/jobs.yaml          zuul.d/secrets.yaml         Zuul 내장 변수
     │ vars:                    │ secrets:                  │
     │ weblate_project:         │ weblate_api_credentials:  │ zuul.project.name
     │   "contributor-guide"    │   url: (encrypted)        │ zuul.branch
     │                          │   token: (encrypted)      │ ansible_user_dir
     ▼                          ▼                           ▼
  ┌─────────────────────────────────────────────────────────────┐
  │                     Playbook / Role                         │
  │                                                             │
  │  {{ weblate_project }}           → "contributor-guide"      │
  │  {{ weblate_api_credentials.url }} → "https://weblate..."   │
  │  {{ zuul.project.short_name }}   → "contributor-guide"      │
  │  {{ ansible_user_dir }}          → "/home/ubuntu"           │
  └─────────────────────────────────────────────────────────────┘
```

### 변수 우선순위 (낮은 → 높은)

1. Role defaults (`defaults/main.yaml`)
2. Job vars (`jobs.yaml`의 `vars:`)
3. Playbook vars
4. Zuul 내장 변수
5. Secret 변수

## Playbook에서 Shell 스크립트 실행

Shell 스크립트를 실행할 때는 `shell` 모듈을 사용한다.

```yaml
- hosts: all
  tasks:
    - name: Run translation update
      shell: |
        cd {{ ansible_user_dir }}/{{ zuul.project.src_dir }}
        bash {{ ansible_user_dir }}/scripts/upstream_translation_update_weblate.sh \
          {{ zuul.project.short_name }} \
          {{ zuul.job }} \
          {{ zuul.branch }}
      environment:
        WEBLATE_URL: "{{ weblate_api_credentials.url }}"
        WEBLATE_TOKEN: "{{ weblate_api_credentials.token }}"
```

주의사항:
- `command` vs `shell`: 파이프(`|`), 리다이렉트(`>`), 환경변수가 필요하면 `shell`을 사용
- `environment`: 스크립트에 전달할 환경 변수를 지정
- Secret 값은 환경 변수로 전달하는 것이 일반적

## 실제 예시: pre.yaml 해부

```yaml
# playbooks/base/pre.yaml
- name: Sync workspace to remote node     # ← play 이름
  hosts: all                                # ← 노드에서 실행
  tasks:
    - name: Start zuul_console for live log streaming
      zuul_console:                         # ← Zuul 전용 모듈
      # zuul_console은 노드에서 로그 스트리밍 데몬을 시작한다.
      # 이것이 없으면 shell 스크립트의 stdout이 job 로그에 보이지 않는다.

    - name: Create src directory structure
      file:
        path: "{{ ansible_user_dir }}/{{ zuul.project.src_dir }}"
        state: directory
      # 노드에 소스 디렉토리 구조를 미리 만든다.

    - name: Sync project source from executor to node
      synchronize:
        src: "{{ zuul.executor.work_root }}/src/{{ zuul.project.canonical_name }}/"
        dest: "{{ ansible_user_dir }}/{{ zuul.project.src_dir }}/"
      no_log: true
      # executor에서 checkout한 소스를 노드로 rsync 복사한다.
      # no_log: true로 대량의 rsync 출력을 숨긴다.
```

## 자주 쓰는 Ansible 모듈

| 모듈 | 용도 | 예시 |
|------|------|------|
| `shell` | 쉘 명령 실행 | `shell: bash script.sh` |
| `command` | 명령 실행 (쉘 기능 없이) | `command: python3 test.py` |
| `copy` | 파일 복사 (role files/ → 노드) | `copy: src=script.sh dest=~/` |
| `template` | 템플릿 렌더링 후 복사 | `template: src=config.j2 dest=~/` |
| `file` | 파일/디렉토리 생성/삭제 | `file: path=/tmp/dir state=directory` |
| `pip` | Python 패키지 설치 | `pip: name=sphinx` |
| `synchronize` | rsync 기반 파일 동기화 | 위의 pre.yaml 참고 |
| `zuul_console` | Zuul 로그 스트리밍 시작 | `zuul_console:` |
| `zuul_return` | Zuul에 결과 데이터 반환 | `zuul_return: data: ...` |

## 다음 문서

→ [06. Nodepool과 노드 관리](06-nodepool.md): Worker node를 어떻게 관리하는지 알아본다.
