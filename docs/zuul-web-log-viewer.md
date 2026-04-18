# Zuul 웹 UI 로그 뷰어 설정

> Zuul 웹 UI의 Logs/Console/Task Summary 탭에서 로그를 보기 위해 필요한 설정.
> 2026-04-18 트러블슈팅 과정에서 정리.

## 구조

```
브라우저
  │
  ├── Zuul Web (port 9000) ── API로 빌드 정보 조회 (/api/tenant/.../builds)
  │                            → log_url, artifacts 포함
  │
  └── Log Server (port 8088) ── 실제 로그 파일 서빙 (nginx)
       /usr/share/nginx/html/
         └── {build_uuid}/
               ├── job-output.json      ← Console/Task Summary 탭 데이터
               ├── job-output.json.gz
               ├── job-output.txt
               ├── job-output.txt.gz
               ├── zuul-manifest.json   ← Logs 탭 파일 목록
               └── zuul-manifest.json.gz
```

## 핵심: Logs 탭이 비어 보이는 문제

### 원인

Zuul 웹 UI(React)는 Logs 탭을 렌더링할 때 `zuul-manifest.json`을 **빌드의 artifacts 배열에서만** 찾는다.
`log_url`에서 자동으로 manifest를 가져오지 않는다.

```javascript
// Zuul 웹 UI 내부 로직 (간략화)
for (let artifact of build.artifacts) {
  if (artifact.metadata.type === 'zuul_manifest') {
    manifest = fetch(artifact.url)  // 이걸로만 manifest를 로드
  }
}
// artifacts에 없으면 → manifest = null → Logs 탭 빈 화면
```

### 해결

`post-logs.yaml`의 `zuul_return`에 manifest를 artifact로 등록해야 한다:

```yaml
# playbooks/base/post-logs.yaml
- name: Return log URL to Zuul
  zuul_return:
    data:
      zuul:
        log_url: "http://<ZUUL_HOST_IP>:8088/{{ zuul.build }}/"
        artifacts:                                          # ← 이 부분이 핵심
          - name: "Zuul Manifest"
            url: "http://<ZUUL_HOST_IP>:8088/{{ zuul.build }}/zuul-manifest.json"
            metadata:
              type: zuul_manifest
```

`artifacts`가 없으면 API 응답이 이렇게 되고:
```json
{ "artifacts": [], "log_url": "http://..." }
```
Logs 탭은 영원히 빈 화면이다.

## 부수 문제: nginx Content-Type

### 증상

Console/Task Summary 탭도 안 보이거나 깨짐.

### 원인

Zuul 웹 UI는 `job-output.json.gz`를 직접 요청한다.
nginx 기본 설정은 `.gz` 파일을 `application/octet-stream`으로 서빙해서,
브라우저가 JSON으로 파싱하지 못한다.

### 해결

`etc/nginx/default.conf`에서 `.gz` 파일의 Content-Type과 Content-Encoding을 명시:

```nginx
# .json.gz → Content-Type: application/json + Content-Encoding: gzip
location ~* \.json\.gz$ {
    add_header Content-Encoding gzip always;
    types { }
    default_type application/json;
}

# .txt.gz → Content-Type: text/plain + Content-Encoding: gzip  
location ~* \.txt\.gz$ {
    add_header Content-Encoding gzip always;
    types { }
    default_type text/plain;
}
```

이렇게 하면 브라우저가 `Content-Encoding: gzip`을 보고 자동 압축 해제 → JSON 파싱 성공.

## 체크리스트

로그가 안 보일 때 확인할 것:

1. **빌드 API에 artifacts가 있는가?**
   ```
   curl http://<ZUUL_HOST_IP>:9000/api/tenant/i18n-test/builds?limit=1 | jq '.[0].artifacts'
   ```
   `zuul_manifest` 타입이 있어야 Logs 탭이 동작한다.

2. **manifest URL에 접근 가능한가?**
   ```
   curl http://<ZUUL_HOST_IP>:8088/{build_uuid}/zuul-manifest.json
   ```

3. **`.gz` 파일의 Content-Type이 올바른가?**
   ```
   curl -I http://<ZUUL_HOST_IP>:8088/{build_uuid}/job-output.json.gz
   ```
   `Content-Type: application/json` + `Content-Encoding: gzip`이어야 한다.
   `application/octet-stream`이면 nginx 설정 문제.

4. **CORS 헤더가 있는가?**
   ```
   curl -I http://<ZUUL_HOST_IP>:8088/{build_uuid}/zuul-manifest.json
   ```
   `Access-Control-Allow-Origin: *`가 있어야 한다.
