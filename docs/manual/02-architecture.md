# 02. 아키텍처

## 전체 구성도

```
┌─────────────┐     webhook      ┌─────────────────┐
│   GitHub     │ ───────────────→ │   Scheduler     │
│  (소스 코드)  │                  │  (zuul-scheduler)│
└─────────────┘                  └────────┬────────┘
                                          │ job 배정
                                          ▼
                                 ┌─────────────────┐
                                 │   Executor       │
                                 │ (zuul-executor)  │
                                 │                  │
                                 │ ・소스 checkout   │
                                 │ ・Ansible 실행    │
                                 └────────┬────────┘
                                          │ SSH (Ansible)
                                          ▼
                                 ┌─────────────────┐
                                 │   Worker Node    │
                                 │  (ubuntu-noble)  │
                                 │                  │
                                 │ ・실제 작업 수행   │
                                 └─────────────────┘

┌─────────────┐                  ┌─────────────────┐
│ Nodepool     │ ───────────────→ │  Worker Nodes    │
│ (launcher)   │   노드 생성/관리  │  (VM, 컨테이너)  │
└─────────────┘                  └─────────────────┘

┌─────────────┐
│   Zuul Web   │ ← 브라우저 접속 (빌드 상태, 로그 조회)
│ (zuul-web)   │
└─────────────┘
```

## 각 컴포넌트의 역할

### Scheduler (zuul-scheduler)

Zuul의 두뇌. 모든 것을 조율한다.

- GitHub에서 webhook을 수신한다 (PR 생성, push, 코멘트 등)
- 어떤 pipeline에 해당하는 이벤트인지 판단한다
- 어떤 job을 실행할지 결정한다
- Executor에 job 실행을 지시한다
- `zuul.d/` 아래의 설정 파일을 읽고 파싱한다

**중요**: `zuul.d/` 설정을 변경하면 scheduler를 재시작해야 한다.

```bash
docker restart zuul-test-scheduler-1
```

### Executor (zuul-executor)

실제 작업을 수행하는 일꾼.

- Scheduler로부터 job을 받는다
- Git 저장소에서 소스 코드를 **checkout**한다
- Ansible을 실행하여 playbook을 돌린다
- **Trusted playbook**은 executor에서 직접 실행한다
- Worker node에 SSH로 접속하여 task를 실행한다

**핵심 포인트**: Executor는 소스 코드를 checkout하지만, **원격 노드에 자동으로 복사하지 않는다.**
이것이 `pre.yaml`에서 `synchronize`로 소스를 복사하는 이유이다.

```bash
docker restart zuul-test-executor-1
```

### Nodepool (nodepool-launcher)

Worker node를 관리하는 컴포넌트.

- 어떤 라벨의 노드가 필요한지 파악한다
- 클라우드 API로 VM을 생성하거나, 정적 노드 풀에서 할당한다
- 사용이 끝난 노드를 정리한다

우리 환경에서는 **정적 노드(static provider)**를 사용한다:

```yaml
# nodepool.yaml
providers:
  - name: static-provider
    driver: static
    pools:
      - name: main
        nodes:
          - name: 192.168.0.34
            labels:
              - ubuntu-noble
```

**중요**: nodepool.yaml을 변경하면 launcher를 재시작해야 한다.

```bash
docker restart zuul-test-launcher-1
```

### Zuul Web (zuul-web)

웹 UI와 REST API를 제공한다.

- 빌드 상태 조회
- 로그 뷰어 (zuul-manifest.json 기반)
- REST API (job 수동 트리거 등)

```
http://133.186.247.137:9000/   ← Web UI
http://133.186.247.137:9000/api/  ← REST API
```

## Docker 구성

우리 테스트 환경에서는 모든 Zuul 컴포넌트가 Docker 컨테이너로 실행된다.

```
zuul-test-scheduler-1   ← Scheduler
zuul-test-executor-1    ← Executor
zuul-test-web-1         ← Web UI + API
zuul-test-launcher-1    ← Nodepool Launcher
```

### 재시작이 필요한 경우

| 변경 대상 | 재시작 대상 | 이유 |
|----------|-----------|------|
| `zuul.d/*.yaml` | scheduler + executor | 설정 파일을 메모리에 캐싱하기 때문 |
| `nodepool.yaml` | launcher | 노드 풀 설정이 변경되었으므로 |
| `playbooks/`, `roles/` | **재시작 불필요** | Executor가 매 실행마다 Git에서 최신 코드를 가져옴 |

이 차이는 매우 중요하다:
- `zuul.d/jobs.yaml`을 수정하면 → scheduler 재시작 필요
- `playbooks/base/pre.yaml`을 수정하면 → push만 하면 다음 실행부터 반영

## 데이터 흐름

```
1. GitHub에 push 발생
   ↓
2. Webhook → Scheduler가 수신
   ↓
3. Scheduler: "post pipeline의 upstream-translation-update job을 실행해야 한다"
   ↓
4. Nodepool: ubuntu-noble 라벨의 노드를 할당
   ↓
5. Executor: 소스 코드를 checkout
   ↓
6. Executor: playbooks/base/pre.yaml 실행
   - zuul_console 시작 (노드에서)
   - 소스를 노드로 rsync
   ↓
7. Executor: playbooks/upstream-translation-update/pre.yaml 실행
   - sphinx, babel, weblate client 설치 (노드에서)
   ↓
8. Executor: playbooks/upstream-translation-update/run.yaml 실행
   - POT 추출 및 Weblate 업로드 (노드에서)
   ↓
9. Executor: playbooks/base/post-logs.yaml 실행
   - 로그 저장 (executor에서)
   ↓
10. 결과를 Scheduler에 보고
```

## 다음 문서

→ [03. 설정 구조](03-configuration.md): `zuul.d/` 아래의 설정 파일들을 상세히 살펴본다.
