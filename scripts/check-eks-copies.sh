#!/usr/bin/env bash
# EKS 데모 차트(deploy/eks)의 사본이 원본과 같은지 확인한다.
# Helm은 차트 폴더 밖 파일을 읽지 못해(.Files.Get) deploy/eks/files/에 사본을 둔다.
# 원본만 고치고 사본을 안 고치면 EKS 시연만 예전 화면·스키마로 뜨므로, 다르면 실패시킨다.
# pre-commit(.pre-commit-config.yaml의 eks-copies 훅)과 CI(lint job)에서 돈다.
#
# 사용법 (레포 루트):
#   bash scripts/check-eks-copies.sh          # 확인만. 다르면 종료 코드 1
#   bash scripts/check-eks-copies.sh --fix    # 원본으로 사본을 덮어쓴다
#
# deploy/eks/files/nginx.conf는 EKS 전용(경로 접두어·Helm 템플릿)이라 web/nginx.conf와 일부러 다르다 → 검사하지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 원본 → 사본
PAIRS=(
  "web/index.html deploy/eks/files/index.html"
  "workloads/order/db/schema.sql deploy/eks/files/schema.sql"
  "workloads/order/db/seed.sql deploy/eks/files/seed.sql"
)

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

diffs=0
for pair in "${PAIRS[@]}"; do
  read -r src dst <<<"$pair"
  if [ ! -f "$src" ] || [ ! -f "$dst" ]; then
    echo "없음: $src 또는 $dst" >&2
    diffs=$((diffs + 1))
    continue
  fi
  # 줄 끝(CRLF/LF) 차이는 무시한다 (.gitattributes가 커밋할 때 LF로 맞춤)
  if cmp -s <(tr -d '\r' <"$src") <(tr -d '\r' <"$dst"); then
    continue
  fi
  if [ "$FIX" = "1" ]; then
    tr -d '\r' <"$src" >"$dst"
    echo "맞춤: $src → $dst"
  else
    echo "다름: $src ↔ $dst" >&2
    diffs=$((diffs + 1))
  fi
done

if [ "$diffs" -gt 0 ]; then
  cat >&2 <<EOF

EKS 차트 사본 ${diffs}개가 원본과 다릅니다.
원본을 고쳤다면 사본도 맞춰 같은 커밋에 넣으세요:
  bash scripts/check-eks-copies.sh --fix
EKS에서만 다르게 해야 하는 내용이면 원본에도 같은 변경을 넣어 두 파일을 같게 유지하세요
(예: web/index.html의 BASE_PATH는 로컬에서 빈 값이라 동작이 같습니다).
EOF
  exit 1
fi
[ "$FIX" = "1" ] || echo "EKS 차트 사본 ${#PAIRS[@]}개가 원본과 같습니다."
