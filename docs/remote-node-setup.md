# Remote Node Setup for Zuul Jobs

Zuul job을 원격 Ubuntu 24.04 노드에서 실행하기 위한 설정 가이드.

## 배경

기존에는 Zuul executor 컨테이너(Debian 12) 안에서 `hosts: localhost`로 job을 실행했다.
이 경우 executor 컨테이너에 `apt`가 정상 동작하지 않아 `gettext`, `locales` 등 패키지 설치가 실패하고,
locale 설정도 안 되어 `sphinx-build`가 `locale.Error`를 발생시켰다.

OpenStack 공식 환경처럼 별도의 Ubuntu 24.04 노드에서 job을 실행하면 이 문제가 해결된다.

## 구성 요소

### 1. 원격 노드 정보

| 항목 | 값 |
|------|---|
| 내부 IP (Zuul → 노드) | 192.168.0.34 |
| 외부 IP (개발자 접속) | 133.186.244.143 |
| OS | Ubuntu 24.04.3 LTS |
| Python | 3.12 |
| User | ubuntu |
| SSH Key | ~/.ssh/pyk-public.pem |
| Nodepool Label | ubuntu-noble |

### 2. 노드에 필요한 패키지

```bash
sudo apt-get install -y python3-virtualenv python3-pip python3-venv \
    gettext locales python3-sphinx python3-babel python3-requests \
    python3-openstackdocstheme

sudo locale-gen en_US.UTF-8
```

### 3. PEP 668 대응

Ubuntu 24.04는 시스템 Python에 `pip install`을 차단한다 (PEP 668).
Zuul의 Ansible `pip` 모듈이 동작하려면 아래 설정이 필요하다:

```bash
mkdir -p ~/.config/pip
cat > ~/.config/pip/pip.conf << 'EOF'
[global]
break-system-packages = true
EOF
```

## Nodepool 설정

### nodepool.yaml에 노드 추가

```yaml
labels:
  - name: ubuntu-noble

providers:
  - name: static-provider
    driver: static
    pools:
      - name: main
        nodes:
          - name: 192.168.0.34
            labels:
              - ubuntu-noble
            host-key-checking: false
            python-path: /usr/bin/python3
            connection-type: ssh
            connection-port: 22
            username: ubuntu
```

### SSH Key 배포

Nodepool의 SSH 공개키를 노드의 `authorized_keys`에 등록해야 한다:

```bash
# Zuul 서버에서 실행
cat /home/ubuntu/zuul-test/keys/nodepool_rsa.pub | \
  ssh ubuntu@192.168.0.34 "cat >> ~/.ssh/authorized_keys"
```

### Nodepool Launcher 재시작

```bash
docker restart zuul-test-launcher-1
```

## Zuul Job 설정

### base job (zuul.d/jobs.yaml)

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

### Workspace Sync (playbooks/base/pre.yaml)

Zuul executor는 소스를 checkout하지만, 원격 노드로 자동 동기화하지 않는다.
OpenStack에서는 `zuul/zuul-jobs`의 `prepare-workspace` role이 이 역할을 한다.

우리 구현:

```yaml
- name: Sync workspace to remote node
  hosts: all
  tasks:
    - name: Start zuul_console for live log streaming
      zuul_console:

    - name: Create src directory structure
      file:
        path: "{{ ansible_user_dir }}/{{ zuul.project.src_dir }}"
        state: directory

    - name: Sync project source from executor to node
      synchronize:
        src: "{{ zuul.executor.work_root }}/src/{{ zuul.project.canonical_name }}/"
        dest: "{{ ansible_user_dir }}/{{ zuul.project.src_dir }}/"
```

### 핵심 포인트

| 항목 | 설명 |
|------|------|
| `zuul_console` | 원격 노드에서 실시간 로그 스트리밍에 필수. 없으면 shell stdout이 job log에 안 보임 |
| `synchronize` | executor → 노드 소스 복사. rsync 기반 |
| `hosts: all` | 원격 노드에서 실행 (localhost 아님) |
| `connection: local` 제거 | SSH로 원격 접속 (local 아님) |

### Playbook 변경 사항

| 파일 | 변경 |
|------|------|
| playbooks/base/pre.yaml | 신규 — workspace sync + zuul_console |
| playbooks/upstream-translation-update/pre.yaml | `hosts: all` (was: localhost) |
| playbooks/upstream-translation-update/run.yaml | `hosts: all`, `shell` 모듈 (was: localhost, command) |
| playbooks/base/post-logs.yaml | 변경 없음 — `hosts: localhost` 유지 (로그가 executor에 있음) |

## 트러블슈팅

### 소스 디렉토리가 노드에 없음

**증상**: `No such file or directory: /home/ubuntu/src/github.com/ppiyakk2/contributor-guide`

**원인**: Zuul executor가 소스를 checkout하지만, 원격 노드에는 디렉토리 구조만 생성되고 파일이 복사되지 않음.
trusted playbook에서는 자동 소스 동기화가 이루어지지 않는다.

**해결**: `playbooks/base/pre.yaml`에 `synchronize` task 추가.

### 실시간 로그가 안 보임

**증상**: shell 스크립트 실행 시 `[ubuntu-noble] Waiting on logger` 만 표시되고 stdout이 안 보임.

**원인**: `zuul_console` 데몬이 원격 노드에서 시작되지 않음.

**해결**: `playbooks/base/pre.yaml` 첫 번째 task로 `zuul_console:` 추가.

### virtualenv not found

**증상**: `Failed to find required executable "virtualenv"`

**원인**: 노드에 `python3-virtualenv` 미설치.

**해결**: `sudo apt-get install python3-virtualenv`

### externally-managed-environment (PEP 668)

**증상**: `error: externally-managed-environment`

**원인**: Ubuntu 24.04가 시스템 Python에 pip install 차단.

**해결**: `~/.config/pip/pip.conf`에 `break-system-packages = true`

### curl HTTP 400 in executor

**증상**: executor에서 curl로 Weblate API 호출 시 nginx 400 반환.

**원인**: `curl --config ~/.curlrc` 방식이 executor 컨테이너 환경에서 불안정.

**해결**: Python (`WeblateSetup.get_project`)으로 대체.

## OpenStack 공식 구조와의 비교

| 항목 | OpenStack 공식 | 우리 구현 |
|------|---------------|----------|
| Workspace sync role | `zuul/zuul-jobs`의 `prepare-workspace` | `playbooks/base/pre.yaml`에 직접 구현 |
| zuul_console | `prepare-workspace` role에 포함 | `playbooks/base/pre.yaml`에 직접 추가 |
| Source sync 방식 | `synchronize` (rsync) | 동일 |
| Source 경로 | `{{ zuul.executor.src_root }}` | `{{ zuul.executor.work_root }}/src/{{ canonical_name }}/` |
| 노드 OS | Ubuntu (Noble/Jammy) | Ubuntu 24.04 (Noble) |
