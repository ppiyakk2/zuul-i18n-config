# Zuul CI/CD 기초 교육자료

이 문서는 Zuul을 처음 접하는 사람이 OpenStack 번역 자동화 파이프라인을 이해하고 운영할 수 있도록 작성된 교육자료이다.

## 목차

| 순서 | 문서 | 내용 |
|------|------|------|
| 01 | [Zuul이란](01-what-is-zuul.md) | Zuul의 역할, Jenkins와의 차이, 핵심 특징 |
| 02 | [아키텍처](02-architecture.md) | Scheduler, Executor, Web, Nodepool 등 구성요소 |
| 03 | [설정 구조](03-configuration.md) | Tenant, Pipeline, Job, Project, Secret의 관계 |
| 04 | [Job 실행 모델](04-job-execution.md) | pre-run/run/post-run, trusted vs untrusted, 노드 실행 |
| 05 | [Playbook과 Role](05-playbook-and-role.md) | Ansible 기반 job 작성법, 변수 전달, 디렉토리 구조 |
| 06 | [Nodepool과 노드 관리](06-nodepool.md) | 정적/동적 노드, 라벨, 노드 준비 |
| 07 | [Secret 관리](07-secrets.md) | 암호화, 사용 범위, trusted playbook 제약 |
| 08 | [실전: 번역 파이프라인](08-translation-pipeline.md) | 우리 프로젝트의 전체 흐름과 각 파일의 역할 |

## 대상 독자

- Zuul을 처음 접하는 개발자/인프라 엔지니어
- OpenStack 번역 인프라를 이해하거나 운영해야 하는 사람
- Jenkins나 GitHub Actions 경험은 있지만 Zuul은 처음인 사람

## 사전 지식

- Git 기본 (branch, commit, push, PR)
- YAML 문법
- Ansible 기본 개념 (playbook, task, role)
- CI/CD 파이프라인의 일반적인 개념
