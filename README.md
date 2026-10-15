# unity-codex-connect

unity-codex-connect는 Windows에서 Unity와 Codex의 설치·연동, JSON 복구, 전체 제거를 한 파일로 실행하는 도구입니다.

## 다운로드 및 실행

[unity-codex-connect.bat 다운로드](https://github.com/yungshi/unity-codex-connect/raw/refs/heads/main/unity-codex-connect.bat)

파일을 PC에 저장한 뒤 더블클릭하세요. 별도 PS1 파일 없이 BAT 파일 하나로 실행됩니다.

## 메뉴

| 번호 | 기능 |
| --- | --- |
| 1 | 설치 및 Unity–Codex 연동 |
| 2 | Unity 패키지 JSON의 UTF-8 BOM 복구 |
| 3 | 전체 제거 |
| 4 | 사용 안내 |
| 0 | 종료 |

## 프로젝트 자동 탐색

Unity Hub 기록과 문서·바탕 화면·다운로드, 일반 프로젝트 폴더 및 로컬 드라이브에서 Unity 프로젝트를 찾습니다. 이름, Unity 버전, 경로를 확인하고 번호로 선택하세요.

- `A`: 추가 드라이브 탐색
- `M`: 폴더 직접 선택
- `0`: 프로젝트 선택 취소

탐색에는 시간·깊이·폴더 수 제한이 있습니다. 목록에 없으면 직접 선택하세요.

## 6단계에서 Unity가 열렸는데 진행되지 않을 때

별도 확인 창의 **Unity 열렸음 · 계속 진행** 버튼을 누르세요. CMD 창에서 `M`을 눌러도 됩니다.

Unity가 열리고 패키지 설치와 컴파일이 끝났다고 수동 확인하면 Pipeline 설치·Unity 열기 명령의 대기와 자동 준비 확인을 건너뛰고 MCP 설정으로 진행합니다. 실행 중인 Unity Editor는 종료하지 않습니다.

자동 확인 실패 시 `A`로 재시도하거나, 버튼/`M`으로 수동 진행, `0` 또는 취소 버튼으로 취소할 수 있습니다. 수동 진행 자체가 실제 연결 성공을 보장하지는 않습니다.

## 설치에서 처리하는 항목

- manifest.json / packages-lock.json의 UTF-8 BOM 검사·복구
- Node.js/npm, Codex CLI, Unity CLI 확인 및 필요 시 설치
- Unity 공식 Codex 플러그인 설치 시도
- 프로젝트의 com.unity.pipeline 패키지 설치
- 프로젝트 로컬 Unity MCP 설정과 Unity CLI Skill 설치
- Unity Editor 연결 상태 점검

지원 환경: Windows 10 21H1 이상, Unity 6.0 이상 프로젝트, 인터넷 연결, Unity 및 Codex 사용 가능한 계정.

## 복구·제거·로그

JSON 복구는 UTF-8 BOM을 제거하며 다른 JSON 문법 오류는 자동으로 고치지 않습니다. 수정 전 원본을 백업합니다.

전체 제거는 모든 Unity Editor를 닫고 `REMOVE ALL`을 정확히 입력해야 시작됩니다. 선택 프로젝트의 Unity 연동과 사용자 전역 Unity MCP 설정, Unity 플러그인, Codex CLI, Unity CLI, Node.js LTS를 제거 대상으로 삼습니다. Node.js를 사용하는 다른 프로그램에도 영향을 줄 수 있습니다.

Unity Editor, Unity Hub, 프로젝트 Assets/Scenes/Scripts는 유지합니다. 로그와 백업 위치는 작업 결과에 표시됩니다.

## 확인한 동작

BAT 메뉴 실행, 프로젝트 탐색, JSON 복구, 설정 정리, 취소 동작을 테스트했습니다. Unity 자동 준비 확인과 수동 버튼 진행은 모의 CLI로 테스트했습니다. 모든 PC 환경에서의 실제 설치·제거를 검증한 것은 아닙니다.

## 공식 문서

- [Unity CLI](https://docs.unity.com/en-us/unity-cli/use-unity-cli)
- [Unity Pipeline](https://docs.unity.com/en-us/unity-production-pipeline/local-tools-cli/unity-pipeline-package)
- [Unity agent plugin](https://github.com/Unity-Technologies/unity-agent-plugin)
- [Codex CLI](https://developers.openai.com/docs/codex/cli)
