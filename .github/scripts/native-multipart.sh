#!/usr/bin/env bash
set -euo pipefail
formal=fae81b438110d7addda5280e507f88dca72b2cf8
base=dc42795fefddd0c3e6fef39564d5f1007369df91
fixed="$GITHUB_WORKSPACE"
proof="$RUNNER_TEMP/beego-proof"
original="$RUNNER_TEMP/beego-original"
mkdir -p "$proof"
printf '%s\n' "$GITHUB_SHA" > "$proof/helper-sha.txt"
git checkout --detach "$formal"
git worktree add --detach "$original" "$base"
snapshot() {
  local folder=$1 label=$2 phase=$3 expected=$4
  (cd "$folder"
   test "$(git rev-parse HEAD)" = "$expected"
   git rev-parse HEAD > "$proof/$label-head-$phase.txt"
   git ls-files -z | xargs -0 sha256sum > "$proof/$label-all-$phase.sha256"
   git diff --exit-code
   git diff --cached --exit-code
   git status --porcelain --untracked-files=no > "$proof/$label-status-$phase.txt"
   test ! -s "$proof/$label-status-$phase.txt")
}
snapshot "$fixed" fixed before "$formal"
snapshot "$original" original before "$base"
test "$(git hash-object client/httplib/httplib.go)" = eef15c5daabb0f1510cf8c92326cd555ccadbfdc
test "$(git hash-object client/httplib/multipart_file_test.go)" = f264ee41ea03ad8fe429ecd15a1ff53e649895b2
test "$(git -C "$original" hash-object client/httplib/httplib.go)" = fca981cea515d8dc6e2eb8c4135b58864e79804b
go version > "$proof/go-version.txt"
go env > "$proof/go-env.txt"
git diff "$base" "$formal" --numstat > "$proof/formal-numstat.txt"
run_check() {
  local name=$1; shift
  set +e
  "$@" > "$proof/$name.log" 2>&1
  local result=$?
  set -e
  printf '%s\n' "$result" > "$proof/$name.exit"
  cat "$proof/$name.log"
}
if [ "$MODE" = quality ]; then
  cd "$RUNNER_TEMP"
  GOBIN="$RUNNER_TEMP/beego-tools" go install golang.org/x/tools/cmd/goimports@v0.21.0
  GOBIN="$RUNNER_TEMP/beego-tools" go install github.com/gordonklaus/ineffassign@v0.1.0
  GOBIN="$RUNNER_TEMP/beego-tools" go install honnef.co/go/tools/cmd/staticcheck@v0.5.1
  export PATH="$RUNNER_TEMP/beego-tools:$PATH"
  go version -m "$RUNNER_TEMP/beego-tools/goimports" > "$proof/goimports-build.txt"
  go version -m "$RUNNER_TEMP/beego-tools/ineffassign" > "$proof/ineffassign-build.txt"
  staticcheck -version > "$proof/staticcheck-version.txt"
  for label in original fixed; do
    if [ "$label" = original ]; then folder=$original; revision=$base; else folder=$fixed; revision=$formal; fi
    cd "$folder"
    run_check "$label-ineffassign" ineffassign .
    run_check "$label-staticcheck-guide" staticcheck -show-ignored -checks '-ST1017,-U1000,-ST1005,-S1034,-S1012,-SA4006,-SA6005,-SA1019,-SA1024' ./
    run_check "$label-staticcheck-all" staticcheck -show-ignored -checks '-ST1017,-U1000,-ST1005,-S1034,-S1012,-SA4006,-SA6005,-SA1019,-SA1024' ./...
    run_check "$label-gofmt-all" bash -c 'gofmt -l $(git ls-files "*.go"); test -z "$(gofmt -l $(git ls-files "*.go"))"'
    for formatter in guide make; do
      copy="$RUNNER_TEMP/$label-$formatter"
      git worktree add --detach "$copy" "$revision"
      cd "$copy"
      if [ "$formatter" = guide ]; then
        run_check "$label-$formatter-command" goimports -w -format-only ./
      else
        run_check "$label-$formatter-command" make fmt
      fi
      git diff --binary > "$proof/$label-$formatter.patch"
      git diff --numstat > "$proof/$label-$formatter-numstat.txt"
      set +e
      git diff --exit-code > "$proof/$label-$formatter-diff.log"
      result=$?
      set -e
      printf '%s\n' "$result" > "$proof/$label-$formatter-diff.exit"
      cd "$folder"
    done
  done
  cd "$fixed"
  gofmt -d client/httplib/httplib.go client/httplib/multipart_file_test.go > "$proof/scoped-gofmt.patch"
  goimports -d -format-only client/httplib/httplib.go client/httplib/multipart_file_test.go > "$proof/scoped-guide-format.patch"
else
  export CGO_ENABLED=1
  export GOPATH=/home/runner/go
  go env > "$proof/go-env-runtime.txt"
  printf 'GOPATH=%s\nCGO_ENABLED=%s\n' "$GOPATH" "$CGO_ENABLED" > "$proof/native-environment.txt"
  docker run -d --name beego-etcd -p 2379:2379 -p 2380:2380 gcr.io/etcd-development/etcd:v3.4.16 /usr/local/bin/etcd --name s1 --data-dir /etcd-data --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://0.0.0.0:2379 --listen-peer-urls http://0.0.0.0:2380 --initial-advertise-peer-urls http://0.0.0.0:2380 --initial-cluster s1=http://0.0.0.0:2380 --initial-cluster-token tkn --initial-cluster-state new
  sudo systemctl start mysql
  ready=false
  for attempt in $(seq 1 60); do
    if mysql -u root -proot -e 'select 1;' > "$proof/mysql-ready.log" 2>&1 &&
       PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d orm_test -c 'select 1;' > "$proof/postgres-ready.log" 2>&1 &&
       docker exec beego-etcd /usr/local/bin/etcdctl endpoint health > "$proof/etcd-ready.log" 2>&1 &&
       python3 - <<'PY' > "$proof/cache-ready.log" 2>&1
import socket
for port, request, expected in [(6379,b'*1\r\n$4\r\nPING\r\n',b'+PONG'),(11211,b'version\r\n',b'VERSION'),(8888,b'4\ninfo\n\n',b'ok')]:
    with socket.create_connection(('localhost',port),timeout=2) as conn:
        conn.settimeout(2)
        conn.sendall(request)
        response=conn.recv(1024)
        print(port,repr(response))
        assert expected in response,(port,response)
PY
    then ready=true; break; fi
    sleep 1
  done
  test "$ready" = true
  docker inspect $(docker ps -q) > "$proof/service-inspect.json"
  docker logs beego-etcd > "$proof/etcd-start.log" 2>&1
  cd "$fixed"
  run_check fixed-frozen-regression go test -json -race -count=1 -run '^(TestPostFileUnreadable|TestPostFileMultipartSuccess|TestMultipartBodyFileError)$' ./client/httplib
  run_check fixed-httplib-all go test -json -race -count=1 ./client/httplib
  for label in original fixed; do
    if [ "$label" = original ]; then folder=$original; else folder=$fixed; fi
    cd "$folder"
    for keyval in 'current.float 1.23' 'current.bool true' 'current.int 11' 'current.string hello' 'current.serialize.name test' 'sub.sub.key1 sub.sub.key'; do
      read -r key value <<< "$keyval"
      docker exec beego-etcd /usr/local/bin/etcdctl put "$key" "$value" >> "$proof/$label-etcd-seed.log"
    done
    mkdir -p "$RUNNER_TEMP/sqlite-$label"
    export ORM_DRIVER=sqlite3 ORM_SOURCE="$RUNNER_TEMP/sqlite-$label/orm_regular.db"
    run_check "$label-sqlite-orm-regular" go test -json -count=1 -covermode=atomic -coverprofile="$proof/$label-sqlite-regular.cover" ./client/orm/...
    export ORM_DRIVER=sqlite3 ORM_SOURCE="$RUNNER_TEMP/sqlite-$label/orm_test.db"
    run_check "$label-sqlite-orm" go test -json -race -count=1 -covermode=atomic -coverprofile="$proof/$label-sqlite.cover" ./client/orm/...
    PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres -c 'DROP DATABASE IF EXISTS orm_test;' -c 'CREATE DATABASE orm_test;' > "$proof/$label-postgres-reset.log"
    export ORM_DRIVER=postgres ORM_SOURCE='host=localhost port=5432 user=postgres password=postgres dbname=orm_test sslmode=disable'
    run_check "$label-postgres-orm-regular" go test -json -count=1 -covermode=atomic -coverprofile="$proof/$label-postgres-regular.cover" ./client/orm/...
    PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres -c 'DROP DATABASE IF EXISTS orm_test;' -c 'CREATE DATABASE orm_test;' > "$proof/$label-postgres-race-reset.log"
    run_check "$label-postgres-orm" go test -json -race -count=1 -covermode=atomic -coverprofile="$proof/$label-postgres.cover" ./client/orm/...
    mysql -u root -proot -e 'DROP DATABASE IF EXISTS orm_test; CREATE DATABASE orm_test;' > "$proof/$label-mysql-reset.log" 2>&1
    export ORM_DRIVER=mysql ORM_SOURCE='root:root@/orm_test?charset=utf8'
    run_check "$label-mysql-full-regular" go test -json -count=1 -covermode=atomic -coverprofile="$proof/$label-full-regular.cover" ./...
    mysql -u root -proot -e 'DROP DATABASE IF EXISTS orm_test; CREATE DATABASE orm_test;' > "$proof/$label-mysql-race-reset.log" 2>&1
    run_check "$label-mysql-full" go test -json -race -count=1 -covermode=atomic -coverprofile="$proof/$label-full.cover" ./...
    run_check "$label-vet" go vet ./...
  done
  cd "$fixed"
  gofmt -d client/httplib/httplib.go client/httplib/multipart_file_test.go > "$proof/scoped-gofmt.patch"
fi
snapshot "$fixed" fixed after "$formal"
snapshot "$original" original after "$base"
cmp "$proof/fixed-all-before.sha256" "$proof/fixed-all-after.sha256"
cmp "$proof/original-all-before.sha256" "$proof/original-all-after.sha256"
test ! -s "$proof/scoped-gofmt.patch"
if [ "$MODE" = quality ]; then
  test ! -s "$proof/scoped-guide-format.patch"
fi
result=0
for status in "$proof"/*.exit; do
  test "$(cat "$status")" = 0 || result=1
done
exit "$result"
