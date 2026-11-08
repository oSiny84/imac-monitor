# Mac 테스트 ZIP 다운로드

최신 소스에는 **슬림 모드(10분마다 깨어나 확인), 텔레그램 명령, 용량 제한 예약 녹화**가 들어 있습니다. [기능 8 문서](../docs/FEATURE_8_SLIM_MODE_CHAT_SCHEDULE.md)를 참고하세요. 핵심 기능은 그대로 **원할 때만 켜지는 원격 실시간 영상**([기능 7 문서](../docs/FEATURE_7_REMOTE_LIVE_ON_DEMAND.md))입니다. 두 변경의 Swift 소스는 2026-11-08 Mac에서 처음 컴파일되었고, 그때 실패한 테스트 1개를 고쳤습니다. 2026-10-20 기능 1~6과 2026-10-23 빌드 도구·Xcode 14.2 컴파일 수정도 포함합니다. Xcode 선택 확인, Monterey용 FFmpeg 설치 안내, Xcode 14.2 SDK 컴파일 오류와 lipo 인자 순서 수정은 [2026-10-23 문서](../docs/RECHECK_2026-10-23.md), 다운로드 검증·웹 첫 화면·녹화·감시 복구 수정과 테스트 기록은 [2026-10-20 재점검 문서](../docs/RECHECK_2026-10-20.md)에 있습니다. 기능별 설명은 [최신 수정 기록](../docs/REVIEW_FIXES_2026-10-20.md), [감지·제외 영역](../docs/FEATURE_5_MOTION_REGIONS.md), [원격 화질과 자동 조절](../docs/FEATURE_6_REMOTE_QUALITY.md), [기존 구현 안내](../IMPLEMENTATION_PLAN.md)를 참고하세요. 제거는 폴더 안의 `Uninstall MacMonitor.command`로 합니다. 실제 Mac 빌드·카메라·전원·네트워크 인수는 아직 대기 중입니다.

**받을 파일: `MacMonitor-Mac-Test-20261108-191137-182949.zip`** — 슬림 모드·텔레그램·예약 녹화, 2026-11-07 재검토 수정 4건, MediaMTX 다운로드 대체 경로, 첫 Mac 빌드에서 실패한 테스트 수정까지 포함한 ZIP입니다(134개 파일, SHA256 `27d84d5db0cfb5fa598e079284bdcec188578778b4e3be7c6501995e582b8421`). 이보다 이전 ZIP은 받지 마세요. `MacMonitor-Mac-Test-20261108-180425-323986.zip`은 예약 녹화 보관 테스트 1개가 실패해 빌드가 멈추고, `MacMonitor-Mac-Test-20261108-154907-140064.zip`은 GitHub 릴리스 다운로드가 504를 내면 MediaMTX 준비에서 빌드가 멈추고, `MacMonitor-Mac-Test-20261107-152715-495760.zip`에는 기능 8과 재검토 수정이, `MacMonitor-Mac-Test-20261023-210002-606130.zip`에는 기능 1~6이, `MacMonitor-Mac-Test-20261020-174546-149165.zip`에는 2026-10-23 빌드 수정이 빠져 있습니다.

GitHub **Releases** 탭의 최신 `mac-test-*` 릴리즈에 같은 이름의 ZIP이 첨부되어 있습니다. 거기서 받는 것이 가장 쉽습니다. 저장소 안의 이 `releases` 폴더에도 같은 파일이 있으며, 파일을 클릭한 뒤 **Download raw file** 버튼으로 받을 수 있습니다. 두 곳의 파일은 같고 SHA256도 같습니다.

1. Mac에서 ZIP을 풀고 `MacMonitor` 폴더를 통째로 유지합니다.
2. `MAC_TEST_START_HERE.txt`의 준비 사항과 테스트 순서를 읽습니다.
3. `Build MacMonitor.command`를 더블클릭합니다.

ZIP은 완성된 앱이 아닌 소스·테스트·빌드 스크립트 묶음입니다. 현재 빌드는 Intel Mac, macOS Monterey 12.5 이상, Xcode 14.2 / Swift 5.7.x, Go 1.26.x, VideoToolbox 인코더를 제공하는 FFmpeg를 요구합니다. 개발 도구는 별도 준비가 필요합니다. 실제 Mac 빌드·전원·카메라 동작은 아직 검증 전입니다.

Windows에서 새 ZIP을 만들 때는 저장소 루트에서 `python scripts/package-mac-source.py`를 실행합니다. Git에 포함할 수 있도록 이 폴더에 생성하며, 실행 권한과 셸 스크립트 LF 줄바꿈 및 압축 내용을 검사합니다. 생성 후 ZIP도 커밋·푸시해야 GitHub에서 받을 수 있습니다.
