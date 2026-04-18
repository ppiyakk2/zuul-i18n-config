# 01. Zuul이란

## Zuul의 정체

Zuul은 OpenStack 커뮤니티가 만든 **프로젝트 게이팅 시스템(Project Gating System)**이다.
단순한 CI/CD 도구가 아니라, "이 코드가 merge되어도 안전한가?"를 보장하는 데 초점을 맞춘다.

OpenStack은 수백 개의 프로젝트가 서로 의존하며 동시에 개발된다.
한 프로젝트의 변경이 다른 프로젝트를 깨뜨리는 일이 빈번했고, 이를 자동으로 검증하기 위해 Zuul이 탄생했다.

## Jenkins와 무엇이 다른가

| 관점 | Jenkins | Zuul |
|------|---------|------|
| 설정 위치 | Jenkins UI 또는 Jenkinsfile | **Git 저장소 안의 YAML 파일** |
| Job 정의 | 프리스타일/파이프라인/Groovy | **Ansible playbook** |
| 실행 환경 | Jenkins agent (영구 서버) | **일회용 노드** (Nodepool이 관리) |
| 트리거 | 웹훅, 폴링, 수동 | **Pipeline 정의에 따른 이벤트 기반** |
| 멀티 프로젝트 | 플러그인 조합 | **네이티브 지원** (cross-project testing) |
| 설정 변경 | UI에서 수정 → 즉시 적용 | Git push → Zuul이 자동 반영 |

### 핵심 차이: "설정이 코드다"

Jenkins에서는 job 설정을 UI에서 클릭하거나 Jenkinsfile을 프로젝트에 넣는다.
Zuul에서는 **별도의 config 저장소**에 모든 설정이 YAML로 존재하고, Git push만으로 설정이 반영된다.

```
# Jenkins 방식
프로젝트 저장소/
  └── Jenkinsfile          ← job 정의가 프로젝트 안에

# Zuul 방식
config 저장소/             ← 설정 전용 저장소
  ├── zuul.d/
  │   ├── pipelines.yaml   ← 파이프라인 정의
  │   ├── jobs.yaml        ← job 정의
  │   └── projects.yaml    ← 프로젝트-job 매핑
  ├── playbooks/           ← 실제 실행 로직 (Ansible)
  └── roles/               ← 재사용 가능한 작업 단위
```

### 핵심 차이: "Ansible이 실행 엔진이다"

Jenkins는 shell script, Groovy, 플러그인을 조합해서 job을 만든다.
Zuul은 **Ansible playbook이 곧 job**이다.

```yaml
# Zuul job의 실행 로직은 Ansible playbook
- hosts: all
  tasks:
    - name: Run tests
      shell: tox -e py39
```

이 차이가 중요한 이유:
- Ansible의 모든 모듈을 그대로 사용할 수 있다 (파일 복사, 패키지 설치, 템플릿 등)
- Role로 재사용 가능한 빌딩 블록을 만들 수 있다
- 변수, 조건문, 루프 등 Ansible의 모든 기능을 활용할 수 있다

## Zuul의 핵심 특징

### 1. 게이팅 (Gating)

PR이 merge되기 전에 "merge 후의 상태"를 미리 테스트한다.
A와 B 두 PR이 동시에 올라오면, Zuul은 "A+B가 동시에 merge된 상태"까지 테스트한다.

### 2. 멀티 프로젝트 의존성

```yaml
- job:
    name: my-job
    required-projects:
      - org/library-a
      - org/library-b
```

job이 실행될 때 의존 프로젝트들도 함께 checkout된다.
라이브러리가 변경되었을 때 그 라이브러리를 쓰는 프로젝트에서 테스트를 돌릴 수 있다.

### 3. Config-as-Code

모든 설정이 Git에 있으므로:
- 설정 변경에 대한 리뷰가 가능하다
- 설정 변경 이력을 git log로 추적할 수 있다
- 실수로 설정이 날아가도 복구할 수 있다

## 우리가 Zuul을 쓰는 이유

OpenStack 번역 인프라는 원래 Zuul 위에서 돌아간다.
우리는 이 구조를 그대로 활용하여:

1. 코드가 merge되면 → **자동으로 번역 원본(POT)을 추출**하여 Weblate에 업로드
2. 매일 정해진 시간에 → **Weblate에서 번역을 다운로드**하여 PR로 제안

이 두 가지 워크플로우를 Zuul의 **post 파이프라인**과 **periodic 파이프라인**으로 구현했다.

## 다음 문서

→ [02. 아키텍처](02-architecture.md): Zuul을 구성하는 컴포넌트들을 알아본다.
