# Mac 테스트 ZIP 다운로드

최신 수정본은 **2026-10-23**입니다. 이전 ZIP 대신 새 날짜 파일을 받으세요. Xcode 선택 확인과 Swift 버전 인식 수정은 [2026-10-23 문서](../docs/RECHECK_2026-10-23.md), 다운로드 검증·웹 첫 화면·녹화·감시 복구 수정과 테스트 기록은 [2026-10-20 재점검 문서](../docs/RECHECK_2026-10-20.md)에 있습니다.

이 폴더의 날짜가 가장 최신인 `MacMonitor-Mac-Test-*.zip`을 클릭하고 GitHub의 **Download raw file** 버튼으로 받으세요. GitHub Releases 탭이 아니라 저장소 안의 `releases` 폴더입니다.

1. Mac에서 ZIP을 풀고 `MacMonitor` 폴더를 통째로 유지합니다.
2. `MAC_TEST_START_HERE.txt`의 준비 사항과 테스트 순서를 읽습니다.
3. `Build MacMonitor.command`를 더블클릭합니다.

ZIP은 완성된 앱이 아닌 소스·테스트·빌드 스크립트 묶음입니다. 현재 빌드는 Intel Mac, macOS Monterey 12.5 이상, Xcode 14.2 / Swift 5.7.x, Go 1.26.x, VideoToolbox 인코더를 제공하는 FFmpeg를 요구합니다. 개발 도구는 별도 준비가 필요합니다. 실제 Mac 빌드·전원·카메라 동작은 아직 검증 전입니다.

Windows에서 새 ZIP을 만들 때는 저장소 루트에서 `python scripts/package-mac-source.py`를 실행합니다. Git에 포함할 수 있도록 이 폴더에 생성하며, 실행 권한과 셸 스크립트 LF 줄바꿈 및 압축 내용을 검사합니다. 생성 후 ZIP도 커밋·푸시해야 GitHub에서 받을 수 있습니다.
