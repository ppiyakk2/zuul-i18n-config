# 06. Nodepool과 노드 관리

## Nodepool이란

Nodepool은 Zuul job이 실행될 Worker node를 관리하는 컴포넌트이다.

OpenStack 환경에서는 클라우드 API로 VM을 자동 생성/삭제하지만,
우리 테스트 환경에서는 **정적 노드(static provider)**를 사용한다.
미리 준비된 서버를 Nodepool에 등록하고, job이 요청할 때 할당한다.

## 정적 노드 설정

```yaml
# /home/ubuntu/zuul-test/etc/nodepool/nodepool.yaml (Zuul 서버에서)

labels:
  - name: ubuntu-noble

providers:
  - name: static-provider
    driver: static
    pools:
      - name: main
        nodes:
          - name: 192.168.0.34        # Zuul에서 접속할 IP (내부)
            labels:
              - ubuntu-noble           # 이 노드에 부여할 라벨
            host-key-checking: false   # SSH host key 확인 비활성화
            python-path: /usr/bin/python3
            connection-type: ssh
            connection-port: 22
            username: ubuntu           # SSH 접속 사용자
```

### 라벨(Label)

라벨은 노드의 종류를 나타내는 태그이다.
Job에서 `nodeset`으로 라벨을 지정하면 해당 라벨의 노드가 할당된다.

```yaml
# zuul.d/jobs.yaml
- job:
    name: base
    nodeset:
      nodes:
        - name: ubuntu-noble      # 이 이름으로 playbook에서 참조
          label: ubuntu-noble      # Nodepool에 요청할 라벨
```

## 노드 준비

### 필수 패키지

```bash
# Ubuntu 24.04 노드에 필요한 패키지
sudo apt-get install -y \
    python3-virtualenv python3-pip python3-venv \
    gettext locales \
    python3-sphinx python3-babel python3-requests python3-openstackdocstheme

sudo locale-gen en_US.UTF-8
```

### SSH Key 배포

Nodepool이 노드에 SSH로 접속해야 하므로, Nodepool의 공개키를 노드에 등록한다.

```bash
# Zuul 서버에서 실행
cat /home/ubuntu/zuul-test/keys/nodepool_rsa.pub | \
  ssh ubuntu@192.168.0.34 "cat >> ~/.ssh/authorized_keys"
```

### PEP 668 대응 (Ubuntu 24.04)

Ubuntu 24.04는 시스템 Python에 pip install을 차단한다.
Zuul의 Ansible pip 모듈이 동작하려면:

```bash
# 노드에서 실행
mkdir -p ~/.config/pip
cat > ~/.config/pip/pip.conf << 'EOF'
[global]
break-system-packages = true
EOF
```

## 노드와 Executor의 관계

```
┌────────────────────┐                    ┌────────────────────┐
│     Executor       │                    │   Worker Node      │
│ (Debian 12 컨테이너) │     SSH (rsync)    │ (Ubuntu 24.04 VM)  │
│                    │ ──────────────────→ │                    │
│ 소스 checkout 보유  │                    │ 실제 작업 수행       │
│ Secret 복호화 가능  │                    │ 패키지 설치 가능     │
│ apt 사용 불가      │                    │ apt 정상 동작       │
└────────────────────┘                    └────────────────────┘
```

### 왜 별도 노드가 필요한가?

Executor 컨테이너(Debian 12)에서 직접 작업하면:

| 문제 | 설명 |
|------|------|
| apt 동작 불량 | Debian 12 기반 컨테이너에서 apt-get이 제대로 동작하지 않음 |
| locale 미설정 | `sphinx-build`가 `locale.Error` 발생 |
| 환경 차이 | OpenStack 공식 환경(Ubuntu)과 다름 |

별도 Ubuntu 24.04 노드에서 실행하면 이 문제들이 해결된다.

## 노드 상태 확인

```bash
# Nodepool 노드 목록 확인
docker exec zuul-test-launcher-1 nodepool list

# 특정 노드 상태
ssh ubuntu@133.186.244.143 "uname -a && python3 --version"
```

## 노드 추가/변경 시

1. `nodepool.yaml` 수정
2. Nodepool launcher 재시작:
   ```bash
   docker restart zuul-test-launcher-1
   ```
3. 새 노드에 SSH key 배포
4. 새 노드에 필수 패키지 설치

## 동적 노드 (참고)

OpenStack 프로덕션에서는 **동적 노드**를 사용한다.

```yaml
# 동적 노드 예시 (우리는 사용하지 않음)
providers:
  - name: openstack-provider
    driver: openstack
    cloud: mycloud
    pools:
      - name: main
        max-servers: 10
        labels:
          - name: ubuntu-noble
            min-ram: 8192
            diskimage: ubuntu-noble
```

동적 노드의 특징:
- Job마다 새 VM을 생성하고, 끝나면 삭제한다
- 항상 깨끗한 환경에서 시작한다
- 클라우드 비용이 발생한다

정적 노드는 재사용되므로 이전 job의 파일이 남아있을 수 있다.
스크립트에서 `rm -rf`로 이전 결과를 정리하는 이유이다.

## 다음 문서

→ [07. Secret 관리](07-secrets.md): 인증 정보를 안전하게 관리하는 방법을 알아본다.
