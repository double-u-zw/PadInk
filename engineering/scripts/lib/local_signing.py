#!/usr/bin/env python3
"""Choose an Xcode signing team without changing an existing installation's identity."""
import argparse
import datetime
import plistlib
import re
import subprocess
import sys
from pathlib import Path

TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")


def validate_team(team):
    team = team.strip().upper()
    if not TEAM_ID.fullmatch(team):
        raise ValueError("团队 ID 应为 10 位英文字母或数字。请使用 Xcode 中自己的 Apple ID 团队，不要使用安装指南中的示例。")
    return team


def teams_from_settings(settings):
    teams = {}
    accounts = settings.get("IDEProvisioningTeamByIdentifier", {}) if isinstance(settings, dict) else {}
    for account in accounts.values() if isinstance(accounts, dict) else []:
        for team in account if isinstance(account, list) else []:
            if not isinstance(team, dict):
                continue
            identifier = team.get("teamID", "")
            if isinstance(identifier, str) and TEAM_ID.fullmatch(identifier):
                teams[identifier] = (identifier, str(team.get("teamName") or identifier))
    return sorted(teams.values(), key=lambda team: (team[1], team[0]))


def read_teams():
    result = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True)
    if result.returncode != 0:
        return []
    try:
        return teams_from_settings(plistlib.loads(result.stdout))
    except (plistlib.InvalidFileException, ValueError, TypeError):
        return []


def existing_identity(path):
    text = path.read_text()
    team = re.search(r"^DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]+)\s*$", text, re.MULTILINE)
    prefix = re.search(r"^PADINK_BUNDLE_PREFIX\s*=\s*([^\s]+)\s*$", text, re.MULTILINE)
    if not team or not prefix:
        raise ValueError("本机签名配置不完整。请保留此文件，并把 Config/Signing.local.xcconfig 的情况交给维护者；不要删除 iPad 上的 PadInk。")
    identifier = validate_team(team.group(1))
    if prefix.group(1) != "dev.padink03." + identifier.lower():
        raise ValueError("本机团队与 bundle 前缀不一致。继续安装会改变 App 身份，请联系维护者核对 Config/Signing.local.xcconfig；不要删除已有 App。")
    return identifier, prefix.group(1)


def write_identity(root, team):
    team = validate_team(team)
    out = root / "Config/Signing.local.xcconfig"
    if out.exists():
        existing_team, prefix = existing_identity(out)
        if team != existing_team:
            raise ValueError(f"已有安装使用团队 {existing_team}。本次选择的 {team} 不同，已保留原配置；请使用原 Apple ID 续期。")
        return prefix
    prefix = "dev.padink03." + team.lower()
    out.parent.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    out.write_text(f"// Generated {timestamp} by engineering/scripts/configure-local-signing.sh. Do not commit.\nDEVELOPMENT_TEAM = {team}\nPADINK_BUNDLE_PREFIX = {prefix}\n")
    return prefix


def choose_team(teams, interactive):
    if len(teams) == 1:
        print(f"使用 Xcode 团队：{teams[0][1]}（{teams[0][0]}）")
        return teams[0][0]
    if not teams:
        raise ValueError("没有找到 Xcode 中的 Apple ID 团队。请打开 Xcode › 设置 › 账户，登录自己的 Apple ID，等待 Personal Team 显示后重新运行“首次设置 PadInk”。若账户已登录，先在 Xcode 中重新选中它以刷新团队。")
    print("检测到多个 Xcode 团队。请选择你自己的 Personal Team；以后续期继续使用同一团队：")
    for index, (identifier, name) in enumerate(teams, 1):
        print(f"  {index}. {name}（{identifier}）")
    if not interactive:
        raise ValueError("非交互运行无法代选团队。请双击“首次设置 PadInk”，或将团队 ID 作为 configure-local-signing.sh 的参数。")
    choice = input("输入团队前的数字并按回车：").strip()
    if not choice.isdecimal() or not 1 <= int(choice) <= len(teams):
        raise ValueError("没有选择有效团队，未写入配置。请重新运行“首次设置 PadInk”。")
    return teams[int(choice) - 1][0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("team", nargs="?")
    parser.add_argument("--check", action="store_true", help="Validate an existing local config without creating one")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    out = root / "Config/Signing.local.xcconfig"
    try:
        if out.exists():
            team, prefix = existing_identity(out)
            if args.team and validate_team(args.team) != team:
                raise ValueError(f"已有安装使用团队 {team}，已保留原配置。请使用原 Apple ID 续期，勿切换团队。")
            print(f"保留本机签名：团队 {team}；App 前缀 {prefix}。")
            print("每周更新无需重做首次设置，也不要删除本机签名配置。")
            return 0
        if args.check:
            raise ValueError("还没有完成首次设置。请先双击“首次设置 PadInk”。")
        team = validate_team(args.team) if args.team else choose_team(read_teams(), sys.stdin.isatty())
        prefix = write_identity(root, team)
        print(f"已保存本机签名：团队 {team}；App 前缀 {prefix}。")
        print("配置仅保存在这份 PadInk 文件夹。请保留文件夹，用它完成每周更新。")
        return 0
    except (ValueError, OSError, EOFError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
