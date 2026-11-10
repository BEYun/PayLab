#!/bin/bash
# 커밋 hook(.claude/hooks/require-tests-before-commit.sh)이 어떤 명령을 막고 통과시키는지 확인한다.
# 전체 테스트 대신 PAYLAB_TEST_CMD(true/false 등)를 넣고, 임시 git 저장소를 cwd로 줘서 실제 저장소를 건드리지 않는다.
set -u
hook="$(git rev-parse --show-toplevel)/.claude/hooks/require-tests-before-commit.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
failed=0

check() {  # check <기대 종료 코드> <PAYLAB_TEST_CMD> <hook 입력>
    local expected=$1 test_cmd=$2 input=$3 actual
    printf '%s' "$input" | PAYLAB_TEST_CMD="$test_cmd" "$hook" > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "$expected" ]; then
        echo "PASS  기대 $expected  PAYLAB_TEST_CMD=$test_cmd  $input"
    else
        echo "FAIL  기대 $expected, 실제 $actual  PAYLAB_TEST_CMD=$test_cmd  $input"
        failed=1
    fi
}

bash_input() { jq -cn --arg command "$1" --arg cwd "$tmp" '{tool_input: {command: $command}, cwd: $cwd}'; }

check 0 false        "$(bash_input 'git status')"
check 0 false        "$(bash_input 'git log --oneline')"
check 0 false        "$(bash_input 'git commit-tree abc')"
check 0 true         "$(bash_input 'git commit -m x')"
check 2 false        "$(bash_input 'git commit -m x')"
check 2 false        "$(bash_input 'cd Modules && git commit -am x')"
check 2 false        "$(bash_input 'git -C . commit -m x')"
check 2 false        "$(bash_input 'git -c user.name=x commit -m x')"
check 2 false        "$(bash_input 'git --no-pager commit -m x')"
check 2 false        "$(bash_input 'git -C "my dir" commit -m x')"
check 2 false        "$(bash_input 'git commit; echo done')"
check 2 false        "$(bash_input $'git \\\ncommit -m x')"
check 2 /nonexistent "$(bash_input 'git commit -m x')"
check 2 true         'not json'
exit $failed
