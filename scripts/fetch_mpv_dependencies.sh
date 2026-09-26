#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# 仓库为私有，/releases/download 直链即使带 token 也可能返回 404，
# 因此默认走 GitHub API 资产端点（releases/assets/{id} + Accept: application/octet-stream）下载。
MPVKIT_DEPS_REPO="${MPVKIT_DEPS_REPO:-hf805864818/vbox-ios}"
MPVKIT_DEPS_TAG="${MPVKIT_DEPS_TAG:-mpvkit-deps-0.0.1}"
MPVKIT_DEPS_ASSET="${MPVKIT_DEPS_ASSET:-MPVKit-xcframework.zip}"
MPVKIT_DEPS_ASSET_SHA="${MPVKIT_DEPS_ASSET_SHA:-MPVKit-xcframework.zip.sha256}"

# 显式直链覆盖：设置了 MPVKIT_DEPS_URL 时改走普通 curl 下载（镜像/自定义地址）。
MPVKIT_DEPS_URL="${MPVKIT_DEPS_URL:-}"
MPVKIT_DEPS_SHA256_URL="${MPVKIT_DEPS_SHA256_URL:-}"
MPVKIT_DEPS_CACHE_DIR="${MPVKIT_DEPS_CACHE_DIR:-.mpv-cache}"
MPVKIT_DEPS_SKIP_INSTALL="${MPVKIT_DEPS_SKIP_INSTALL:-0}"

# 私有仓库 release 资产必须带认证才能下载。
# 优先使用显式传入的 MPVKIT_DEPS_TOKEN，其次复用 CI 自动注入的 GITHUB_TOKEN，
# 最后尝试本地已登录的 gh CLI。
MPVKIT_DEPS_TOKEN="${MPVKIT_DEPS_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$MPVKIT_DEPS_TOKEN" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    MPVKIT_DEPS_TOKEN="$(gh auth token 2>/dev/null || true)"
fi

usage() {
    cat <<'USAGE'
用法: scripts/fetch_mpv_dependencies.sh [选项]

选项:
  --cache-dir <dir>     缓存目录（默认 .mpv-cache，也可用 MPVKIT_DEPS_CACHE_DIR）
  --repo <repo>         GitHub API 仓库（默认 hf805864818/vbox-ios，也可用 MPVKIT_DEPS_REPO）
  --tag <tag>           GitHub API release tag（默认 mpvkit-deps-0.0.1，也可用 MPVKIT_DEPS_TAG）
  --url <url>           显式直链 URL，覆盖 API 方式（也可用 MPVKIT_DEPS_URL）
  --sha256-url <url>    sha256 文件直链地址（默认 <url>.sha256）
  --token <token>       访问私有仓库 release 的认证 token（也可用 MPVKIT_DEPS_TOKEN / GITHUB_TOKEN）
  --skip-install        只下载与校验，不调用 install_mpv_dependencies.sh
  -h, --help            打印帮助

行为:
  1. 通过 GitHub API 解析 release 资产并下载 MPVKit-xcframework.zip 到缓存目录
  2. 下载 sha256 资产文件并校验
  3. 如果缓存中的压缩包 sha256 已匹配，跳过重复下载
  4. 默认调用 install_mpv_dependencies.sh 与 check_mpv_installed_dependencies.py

只服务 MPVKit 内核依赖，不处理后续自由度 libmpv.xcframework。
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --cache-dir)
            MPVKIT_DEPS_CACHE_DIR="$2"
            shift 2
            ;;
        --repo)
            MPVKIT_DEPS_REPO="$2"
            shift 2
            ;;
        --tag)
            MPVKIT_DEPS_TAG="$2"
            shift 2
            ;;
        --url)
            MPVKIT_DEPS_URL="$2"
            MPVKIT_DEPS_SHA256_URL="${MPVKIT_DEPS_SHA256_URL:-${MPVKIT_DEPS_URL}.sha256}"
            shift 2
            ;;
        --sha256-url)
            MPVKIT_DEPS_SHA256_URL="$2"
            shift 2
            ;;
        --token)
            MPVKIT_DEPS_TOKEN="$2"
            shift 2
            ;;
        --skip-install)
            MPVKIT_DEPS_SKIP_INSTALL=1
            shift 1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            usage
            exit 2
            ;;
    esac
done

mkdir -p "$MPVKIT_DEPS_CACHE_DIR"

ARCHIVE_PATH="$MPVKIT_DEPS_CACHE_DIR/MPVKit-xcframework.zip"
SHA256_PATH="$MPVKIT_DEPS_CACHE_DIR/MPVKit-xcframework.zip.sha256"

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

CURL_AUTH=()
if [ -n "$MPVKIT_DEPS_TOKEN" ]; then
    CURL_AUTH=(-H "Authorization: token $MPVKIT_DEPS_TOKEN")
fi

# 通过 GitHub API 按资产名解析资产下载端点（releases/assets/{id}）。
# $1 = 资产名；输出资产 API URL；未找到时输出空串。
github_asset_url() {
    curl -s "${CURL_AUTH[@]}" \
        "https://api.github.com/repos/$MPVKIT_DEPS_REPO/releases/tags/$MPVKIT_DEPS_TAG" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
name = sys.argv[1]
match = [a for a in data.get("assets", []) if a.get("name") == name]
print(match[0]["url"] if match else "")
' "$1" || true
}

DOWNLOAD_MODE="api"
if [ -n "$MPVKIT_DEPS_URL" ]; then
    DOWNLOAD_MODE="url"
fi

echo "MPVKit 依赖下载配置:"
if [ "$DOWNLOAD_MODE" = "api" ]; then
    echo "  mode:       GitHub API release 资产"
    echo "  repo:       $MPVKIT_DEPS_REPO"
    echo "  tag:        $MPVKIT_DEPS_TAG"
    echo "  asset:      $MPVKIT_DEPS_ASSET"
else
    echo "  mode:       直链 URL"
    echo "  url:        $MPVKIT_DEPS_URL"
    echo "  sha256 url: $MPVKIT_DEPS_SHA256_URL"
fi
echo "  cache:      $MPVKIT_DEPS_CACHE_DIR"
if [ -n "$MPVKIT_DEPS_TOKEN" ]; then
    echo "  auth:      已启用（使用 CI token，值不回显）"
else
    echo "  auth:      未启用（公开仓库可不认证；私有仓库需 MPVKIT_DEPS_TOKEN / GITHUB_TOKEN）"
fi

EXPECTED_SHA=""
if [ "$DOWNLOAD_MODE" = "api" ]; then
    SHA_ASSET_URL="$(github_asset_url "$MPVKIT_DEPS_ASSET_SHA")"
    if [ -n "$SHA_ASSET_URL" ]; then
        if curl -L --fail --silent --retry 3 --retry-delay 3 "${CURL_AUTH[@]}" \
            -H "Accept: application/octet-stream" -o "$SHA256_PATH" "$SHA_ASSET_URL"; then
            EXPECTED_SHA="$(awk '{print $1}' "$SHA256_PATH" | head -1)"
            echo "已获取期望 sha256: $EXPECTED_SHA"
        else
            echo "未下载到 sha256 资产，将不做校验。"
            rm -f "$SHA256_PATH"
        fi
    else
        echo "release 中未找到 sha256 资产，将不做校验。"
    fi
else
    if curl -L --fail --silent --retry 3 --retry-delay 3 "${CURL_AUTH[@]}" \
        -o "$SHA256_PATH" "$MPVKIT_DEPS_SHA256_URL"; then
        EXPECTED_SHA="$(awk '{print $1}' "$SHA256_PATH" | head -1)"
        echo "已获取期望 sha256: $EXPECTED_SHA"
    else
        echo "未下载到 sha256 文件，将不做校验。"
        rm -f "$SHA256_PATH"
    fi
fi

NEED_DOWNLOAD=1
if [ -f "$ARCHIVE_PATH" ]; then
    if [ -n "$EXPECTED_SHA" ]; then
        CACHED_SHA="$(sha256_of "$ARCHIVE_PATH")"
        if [ "$CACHED_SHA" = "$EXPECTED_SHA" ]; then
            echo "缓存命中，跳过下载: $ARCHIVE_PATH"
            NEED_DOWNLOAD=0
        fi
    else
        echo "未获取到 sha256（资产可能无 .sha256），复用已有缓存: $ARCHIVE_PATH"
        NEED_DOWNLOAD=0
    fi
fi

if [ "$NEED_DOWNLOAD" -eq 1 ]; then
    echo "下载 MPVKit 依赖包..."
    if [ "$DOWNLOAD_MODE" = "api" ]; then
        ZIP_ASSET_URL="$(github_asset_url "$MPVKIT_DEPS_ASSET")"
        if [ -z "$ZIP_ASSET_URL" ]; then
            echo "release 中未找到资产 $MPVKIT_DEPS_ASSET"
            exit 1
        fi
        curl -L --fail --retry 3 --retry-delay 3 "${CURL_AUTH[@]}" \
            -H "Accept: application/octet-stream" -o "$ARCHIVE_PATH" "$ZIP_ASSET_URL"
    else
        curl -L --fail --retry 3 --retry-delay 3 "${CURL_AUTH[@]}" -o "$ARCHIVE_PATH" "$MPVKIT_DEPS_URL"
    fi
fi

if [ -n "$EXPECTED_SHA" ]; then
    ACTUAL_SHA="$(sha256_of "$ARCHIVE_PATH")"
    if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
        echo "sha256 校验失败"
        echo "  expected: $EXPECTED_SHA"
        echo "  actual:   $ACTUAL_SHA"
        exit 1
    fi
    echo "sha256 校验通过: $ACTUAL_SHA"
fi

if [ "$MPVKIT_DEPS_SKIP_INSTALL" = "1" ]; then
    echo "已按 --skip-install 终止，未调用 install / check。"
    exit 0
fi

scripts/install_mpv_dependencies.sh "$ARCHIVE_PATH"
python3 scripts/check_mpv_installed_dependencies.py --allow-missing-external
