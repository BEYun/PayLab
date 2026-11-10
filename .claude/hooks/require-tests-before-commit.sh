#!/bin/bash
# PreToolUse(Bash) hook: Claude가 git commit을 실행하려 하면 전체 테스트(scripts/test-all.sh)를 먼저 돌린다.
# 실패하면 종료 코드 2로 커밋을 막고, 실패 요약을 Claude에게 보낸다.
# PAYLAB_TEST_CMD는 hook 자체 테스트(scripts/test-hook.sh) 전용이다.
input=$(cat)
# 줄 이어쓰기(\ + 줄바꿈)는 한 줄로 합쳐서 본다.
if ! command=$(jq -er '.tool_input.command // "" | gsub("\\\\\n"; " ")' <<< "$input" 2> /dev/null); then
    echo "커밋 hook: 입력을 읽지 못해 막는다." >&2
    exit 2
fi

# git과 commit 사이에 명령 구분자(; & |)가 없으면 전역 옵션(-c, -C, --no-pager 등)이 있어도 커밋으로 본다.
commit_pattern='(^|[^[:alnum:]_-])git[[:space:]]([^;&|]*[[:space:]])?commit([[:space:];&|)]|$)'
grep -Eq "$commit_pattern" <<< "$command" || exit 0

cwd=$(jq -r '.cwd // empty' <<< "$input")
if ! root=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2> /dev/null); then
    echo "커밋 hook: git 저장소를 찾지 못해 막는다 (cwd: $cwd)." >&2
    exit 2
fi
cd "$root" || exit 2
mkdir -p .build
log=.build/hook-test.log
${PAYLAB_TEST_CMD:-scripts/test-all.sh} > "$log" 2>&1 && exit 0

tail -n 40 "$log" >&2
echo "커밋 차단: 전체 테스트 실패. 테스트를 고친 뒤 다시 커밋한다. 로그: $root/$log" >&2
exit 2
