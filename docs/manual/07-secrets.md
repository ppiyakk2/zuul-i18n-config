# 07. Secret 관리

## Secret이란

Secret은 Zuul에서 API 토큰, 비밀번호 등 민감한 정보를 안전하게 저장하고 사용하는 메커니즘이다.
Git에 평문으로 저장하면 안 되는 값들을 **프로젝트 공개키로 암호화**하여 저장한다.

## Secret의 동작 원리

```
1. 암호화 (개발자 PC)
   평문 → 프로젝트 공개키로 암호화 → secrets.yaml에 저장 → Git push

2. 복호화 (Zuul executor)
   secrets.yaml 읽기 → 프로젝트 비밀키로 복호화 → playbook 변수로 전달
```

중요한 점:
- 암호화에 사용하는 **공개키**는 누구나 볼 수 있다
- 복호화에 사용하는 **비밀키**는 Zuul 서버만 갖고 있다
- Git에 push된 암호문은 Zuul 서버 없이는 복호화할 수 없다

## Secret 생성

### 1단계: 프로젝트 공개키 가져오기

```bash
# Zuul REST API에서 공개키를 가져온다
curl -s "http://<ZUUL_HOST_IP>:9000/api/tenant/i18n-test/key/<your-org>/zuul-i18n-config.pub"
```

### 2단계: 값 암호화

```bash
# zuul-client 또는 zuul encrypt 명령 사용
zuul encrypt --tenant i18n-test \
    --project <your-org>/zuul-i18n-config \
    --secret weblate_api_credentials \
    --field url \
    --infile <(echo -n "https://weblate.example.com/api/")
```

또는 Python으로 직접:

```python
from Crypto.PublicKey import RSA
from Crypto.Cipher import PKCS1_OAEP
import base64

# 공개키 로드
with open("project.pub") as f:
    public_key = RSA.import_key(f.read())

# 암호화
cipher = PKCS1_OAEP.new(public_key)
encrypted = cipher.encrypt(b"https://weblate.example.com/api/")
print(base64.b64encode(encrypted).decode())
```

### 3단계: secrets.yaml에 저장

```yaml
# zuul.d/secrets.yaml
- secret:
    name: weblate_api_credentials
    data:
      url: !encrypted/pkcs1-oaep
        - nSbC7x2F4kD9eA3b...     # 암호화된 URL
      token: !encrypted/pkcs1-oaep
        - aB3kD9eX7mN2pQ...       # 암호화된 토큰
```

## Secret 사용

### Job에서 연결

```yaml
# zuul.d/jobs.yaml
- job:
    name: upstream-translation-update
    secrets:
      - weblate_api_credentials    # ← secret 이름
```

### Playbook에서 접근

Secret이 연결된 job의 playbook에서 변수로 접근할 수 있다.

```yaml
# playbooks/upstream-translation-update/run.yaml
- hosts: all
  tasks:
    - name: Run script
      shell: bash ~/scripts/upstream.sh
      environment:
        WEBLATE_URL: "{{ weblate_api_credentials.url }}"
        WEBLATE_TOKEN: "{{ weblate_api_credentials.token }}"
```

### Template에서 사용

```ini
# roles/prepare-weblate-client/templates/weblate.ini.j2
[weblate]
url = {{ weblate_api_credentials.url }}

[keys]
{{ weblate_api_credentials.url }} = {{ weblate_api_credentials.token }}
```

## Secret의 보안 제약

### Trusted Playbook에서만 사용 가능

Secret은 **config project의 playbook**에서만 접근할 수 있다.

```
config project (zuul-i18n-config)
  └── playbooks/run.yaml        ← Secret 접근 가능 (trusted)

untrusted project (contributor-guide)
  └── .zuul.yaml의 playbook     ← Secret 접근 불가 (untrusted)
```

### Secret 값의 노출 방지

Zuul은 secret 값이 로그에 노출되는 것을 방지한다:
- `debug` 모듈로 secret 변수를 출력하면 `***`로 마스킹된다
- `no_log: true`를 사용하면 task 전체 출력을 숨길 수 있다

```yaml
# 좋은 예: 환경 변수로 전달
- shell: bash script.sh
  environment:
    TOKEN: "{{ secret.token }}"

# 나쁜 예: 명령줄 인자로 전달 (로그에 남을 수 있음)
- shell: bash script.sh --token={{ secret.token }}
```

## Secret 변경 시

Secret 값을 변경하려면:

1. 새 값을 공개키로 암호화
2. `secrets.yaml` 업데이트
3. Git push
4. Scheduler 재시작 (설정 파일이 변경되었으므로)

```bash
docker restart zuul-test-scheduler-1 zuul-test-executor-1
```

## 주의사항

| 사항 | 설명 |
|------|------|
| HTTPS 필수 | URL은 반드시 `https://`를 사용해야 한다. nginx가 `http://`를 거부할 수 있다 |
| 공개키 갱신 | Zuul 서버를 재구축하면 키쌍이 바뀐다. 기존 secret을 모두 재암호화해야 한다 |
| 프로젝트별 키 | 각 config project마다 별도의 키쌍이 존재한다 |

## 다음 문서

→ [08. 실전: 번역 파이프라인](08-translation-pipeline.md): 지금까지 배운 내용을 종합하여 우리 번역 파이프라인의 전체 흐름을 이해한다.
