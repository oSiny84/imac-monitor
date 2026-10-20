# Mac 테스트 ZIP 다운로드

최신 로컬 구현은 **2026-10-20 기능 1·2 추가본**입니다. 같은 날짜가 여러 개면 파일 이름의 시각이 가장 늦은 ZIP을 받으세요. [기능 1 안내](../docs/FEATURE_1_ARCHIVE_ACCESS.md), [기능 2 상태판·프레임 정지 복구](../docs/FEATURE_2_MONITORING_HEALTH.md), [이전 재점검 기록](../docs/RECHECK_2026-10-20.md)을 참고하세요. GitHub 업로드는 Git 인증 갱신이 필요하며 현재 로컬 커밋/ZIP과 원격 저장소 내용이 다를 수 있습니다.

이 폴더의 날짜가 가장 최신인 `MacMonitor-Mac-Test-*.zip`을 클릭하고 GitHub의 **Download raw file** 버튼으로 받으세요. GitHub Releases 탭이 아니라 저장소 안의 `releases` 폴더입니다.

1. Mac에서 ZIP을 풀고 `MacMonitor` 폴더를 통째로 유지합니다.
2. `MAC_TEST_START_HERE.txt`의 준비 사항과 테스트 순서를 읽습니다.
3. `Build MacMonitor.command`를 더블클릭합니다.

ZIP은 완성된 앱이 아닌 소스·테스트·빌드 스크립트 묶음입니다. 현재 빌드는 Intel Mac, macOS Monterey 12.5 이상, Xcode 14.2 / Swift 5.7.x, Go 1.26.x, VideoToolbox 인코더를 제공하는 FFmpeg를 요구합니다. 개발 도구는 별도 준비가 필요합니다. 실제 Mac 빌드·전원·카메라 동작은 아직 검증 전입니다.

Windows에서 새 ZIP을 만들 때는 저장소 루트에서 `python scripts/package-mac-source.py`를 실행합니다. Git에 포함할 수 있도록 이 폴더에 생성하며, 실행 권한과 셸 스크립트 LF 줄바꿈 및 압축 내용을 검사합니다. 생성 후 ZIP도 커밋·푸시해야 GitHub에서 받을 수 있습니다.
