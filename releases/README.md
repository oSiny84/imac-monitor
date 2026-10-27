# Mac 테스트 ZIP 다운로드

최신 소스는 **2026-10-20 기능 1~6에 2026-10-23 빌드 도구·Xcode 14.2 컴파일 수정을 합친 상태**입니다. Xcode 선택 확인, Monterey용 FFmpeg 설치 안내, Xcode 14.2 SDK 컴파일 오류와 lipo 인자 순서 수정은 [2026-10-23 문서](../docs/RECHECK_2026-10-23.md), 다운로드 검증·웹 첫 화면·녹화·감시 복구 수정과 테스트 기록은 [2026-10-20 재점검 문서](../docs/RECHECK_2026-10-20.md)에 있습니다. 기능별 설명은 [최신 수정 기록](../docs/REVIEW_FIXES_2026-10-20.md), [감지·제외 영역](../docs/FEATURE_5_MOTION_REGIONS.md), [원격 화질과 자동 조절](../docs/FEATURE_6_REMOTE_QUALITY.md), [기존 구현 안내](../IMPLEMENTATION_PLAN.md)를 참고하세요. 제거는 폴더 안의 `Uninstall MacMonitor.command`로 합니다. 실제 Mac 빌드·카메라·전원·네트워크 인수는 아직 대기 중입니다.

**받을 파일: `MacMonitor-Mac-Test-20261027-121127-264674.zip`** — 위 합본 소스에 제거 스크립트를 더한 ZIP입니다(117개 파일, SHA256 `c8384d7d8703a513c30df7cea2302477cb900563836fc10b6b7fd452d91c5dc7`). 이보다 이전 ZIP은 받지 마세요. `MacMonitor-Mac-Test-20261023-210002-606130.zip`에는 기능 1~6이, `MacMonitor-Mac-Test-20261020-174546-149165.zip`에는 2026-10-23 빌드 수정이 빠져 있습니다.

이 폴더의 날짜가 가장 최신인 `MacMonitor-Mac-Test-*.zip`을 클릭하고 GitHub의 **Download raw file** 버튼으로 받으세요. GitHub Releases 탭이 아니라 저장소 안의 `releases` 폴더입니다.

1. Mac에서 ZIP을 풀고 `MacMonitor` 폴더를 통째로 유지합니다.
2. `MAC_TEST_START_HERE.txt`의 준비 사항과 테스트 순서를 읽습니다.
3. `Build MacMonitor.command`를 더블클릭합니다.

ZIP은 완성된 앱이 아닌 소스·테스트·빌드 스크립트 묶음입니다. 현재 빌드는 Intel Mac, macOS Monterey 12.5 이상, Xcode 14.2 / Swift 5.7.x, Go 1.26.x, VideoToolbox 인코더를 제공하는 FFmpeg를 요구합니다. 개발 도구는 별도 준비가 필요합니다. 실제 Mac 빌드·전원·카메라 동작은 아직 검증 전입니다.

Windows에서 새 ZIP을 만들 때는 저장소 루트에서 `python scripts/package-mac-source.py`를 실행합니다. Git에 포함할 수 있도록 이 폴더에 생성하며, 실행 권한과 셸 스크립트 LF 줄바꿈 및 압축 내용을 검사합니다. 생성 후 ZIP도 커밋·푸시해야 GitHub에서 받을 수 있습니다.
