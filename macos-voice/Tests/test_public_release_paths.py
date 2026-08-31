from pathlib import Path


ROOT = Path(__file__).parents[2]


def test_runtime_files_do_not_contain_personal_home_path():
    personal_home = "/Users/" + "liangchao"
    paths = [
        ROOT / "macos-voice/Sources/CodexVoiceHotkey/main.swift",
        ROOT / "macos-voice/scripts/install.sh",
        ROOT / "macos-voice/launchd/com.codex.voice-hotkey.plist",
    ]
    for path in paths:
        assert personal_home not in path.read_text(encoding="utf-8")


def test_launch_agent_path_is_resolved_during_install():
    template = (ROOT / "macos-voice/launchd/com.codex.voice-hotkey.plist").read_text(encoding="utf-8")
    installer = (ROOT / "macos-voice/scripts/install.sh").read_text(encoding="utf-8")
    assert "__CLIMC_APP_PATH__" in template
    assert "plutil -replace 'ProgramArguments.3' -string \"$APP\"" in installer


def test_unused_personal_learner_launch_agent_is_not_published():
    assert not (ROOT / "macos-voice/launchd/com.codex.voice-learner.plist").exists()
