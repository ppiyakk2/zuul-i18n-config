# Weblate Browse 기능 미지원 사유

## 현상

Weblate UI에서 컴포넌트의 **Browse** 버튼을 클릭하면 404 Not Found가 발생한다.

예: `https://weblate.example.com/browse/contributor-guide/master/-/` → 404

## 원인

컴포넌트가 `vcs: local`, `repo: local:`로 생성되어 있다. Browse 기능은 Weblate가 관리하는 git 저장소의 파일을 탐색하는 기능인데, `local` VCS 모드에서는 실제 git 저장소가 없으므로 파일 브라우저가 동작하지 않는다.

```
# 현재 컴포넌트 설정 (API 확인)
vcs: local
repo: local:
branch: main
```

## 왜 이렇게 설계했는가

### VCS 연결 방식 (Browse 가능)

Weblate에 git 저장소를 직접 연결하면:

```
Weblate ←→ Git 저장소 (직접 clone/push)
```

- Weblate가 저장소를 clone하고, 번역 변경을 **직접 git commit/push**
- Browse 기능 동작
- **Zuul의 propose-translation-update job이 불필요**

### API 방식 (현재 채택, Browse 불가)

```
Git 저장소 → Zuul (POT 추출) → Weblate API (업로드)
Weblate API (다운로드) → Zuul (PR 생성) → Git 저장소
```

- Zuul job이 Weblate API를 통해 POT 업로드 / PO 다운로드
- 번역 변경은 Zuul이 PR로 제안 (코드 리뷰 가능)
- Weblate는 저장소에 직접 접근하지 않음
- Browse 기능 미지원

### 프로덕션(OpenStack) 환경의 제약

OpenStack 번역 인프라에서 API 방식을 채택한 이유:

1. **저장소 접근 권한**: opendev.org(Gerrit) 저장소에 Weblate가 직접 push할 수 없음
2. **코드 리뷰 프로세스**: 번역 변경도 리뷰를 거쳐야 하므로 Zuul이 변경을 제안(propose)하는 구조가 필요
3. **워크플로우 일관성**: 모든 변경이 CI/CD 파이프라인을 통과하는 OpenStack의 기존 워크플로우와 일치

## 비교 요약

| | VCS 연결 방식 | API 방식 (현재) |
|---|---|---|
| Browse 기능 | 동작 | 미지원 (404) |
| 번역 반영 | Weblate가 직접 push | Zuul job이 PR 생성 |
| 코드 리뷰 | 불가 (자동 커밋) | 가능 (PR 기반) |
| 저장소 권한 | Weblate에 push 권한 필요 | 불필요 |
| Zuul 의존성 | 불필요 | 필요 |
| OpenStack 호환 | 불가 | 호환 |

## 결론

Browse 404는 버그가 아니라 **아키텍처 설계에 의한 의도된 트레이드오프**이다. OpenStack 프로덕션 환경과의 호환성을 위해 API 방식을 채택했으며, 이로 인해 Browse 기능은 사용할 수 없다.
